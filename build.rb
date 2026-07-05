#!/usr/bin/env ruby
# frozen_string_literal: true

# 「わしの日々」素朴 SSG — Jekyll の10%でいい、の初志貫徹
#
#   posts/YYYY-MM-DD-slug.md  →  dist/posts/slug/index.html
#   images/                   →  dist/images/  （そのままコピー。md 内の /images/ 参照が無変換で効く）
#   一覧 = dist/index.html（日付降順） / RSS = dist/feed.xml（最新20件）
#
# 記事の約束事（sizu.me エクスポート互換）:
#   - frontmatter なし。1行目の「# 見出し」がタイトル
#   - 日付はファイル名の YYYY-MM-DD
#   - 画像は ![](/images/xxx.jpeg) の相対参照

require "commonmarker"
require "fileutils"
require "date"
require "time"
require "cgi"
require "yaml"

# CI などロケール未設定環境でも日本語を正しく扱う
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

SITE_TITLE = "わしの日々"
SITE_URL   = "https://taea.kani.show"
ROOT      = __dir__
POSTS     = File.join(ROOT, "posts")
ESA_POSTS = File.join(ROOT, "esa")
DIST      = File.join(ROOT, "dist")

Post = Struct.new(:date, :slug, :title, :body_md, :filename, keyword_init: true) do
  def path = "/posts/#{slug}/"
  def url  = "#{SITE_URL}#{path}"
  def html = Commonmarker.to_html(body_md, options: { render: { unsafe: true } }, plugins: { syntax_highlighter: nil })
end

def load_posts
  Dir.glob(File.join(POSTS, "*.md")).filter_map do |file|
    name = File.basename(file, ".md")
    m = name.match(/\A(\d{4}-\d{2}-\d{2})-(.+)\z/)
    next warn("skip (ファイル名が規約外): #{name}") unless m

    lines = File.read(file).lines
    title_line = lines.find { |l| l.start_with?("# ") }
    title = title_line ? title_line.sub(/\A# /, "").strip : name
    body  = lines.reject { |l| l.equal?(title_line) }.join.strip

    Post.new(date: Date.parse(m[1]), slug: m[2], title:, body_md: body, filename: name)
  end
end

# esa GitHub Webhook の荷受け口（第3工区・2026-07-05）
#
#   esa/{記事番号}.html.md（YAML frontmatter 付き）→ Post
#   - ShipIt 時のみ届く仕様だが、published: true を二重ガードで確認
#   - slug は e{記事番号}: タイトルを後から直しても URL が動かない
#   - 日付: タイトル中の YYYY-MM-DD が最優先。無ければ created_at の営業日
#     （朝4時区切り・寄席方式——深夜に書いた日記は前日に属す）
def load_esa_posts
  Dir.glob(File.join(ESA_POSTS, "*.md")).filter_map do |file|
    raw = File.read(file)
    m = raw.match(/\A---\n(.*?)\n---\n/m)
    next warn("skip (frontmatter なし): #{File.basename(file)}") unless m

    fm = YAML.safe_load(m[1])
    next warn("skip (未公開): #{File.basename(file)}") unless fm["published"]
    next warn("skip (記事番号なし): #{File.basename(file)}") unless fm["number"]

    title = fm["title"].to_s.strip
    body  = raw[m[0].size..].strip
    date  = if (dm = title.match(/(\d{4}-\d{2}-\d{2})/))
              Date.parse(dm[1])
            else
              (Time.parse(fm["created_at"].to_s) - 4 * 3600).to_date
            end

    Post.new(date:, slug: "e#{fm["number"]}", title:, body_md: body,
             filename: File.basename(file, ".md"))
  end
end

def layout(title:, body:, path: "/")
  <<~HTML
    <!DOCTYPE html>
    <html lang="ja">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{CGI.escapeHTML(title)}</title>
      <meta property="og:title" content="#{CGI.escapeHTML(title)}">
      <meta property="og:site_name" content="#{SITE_TITLE}">
      <meta property="og:url" content="#{SITE_URL}#{path}">
      <link rel="stylesheet" href="/assets/style.css">
      <link rel="alternate" type="application/rss+xml" title="#{SITE_TITLE}" href="/feed.xml">
    </head>
    <body>
      <header class="site-header"><a href="/">#{SITE_TITLE}</a></header>
      <main>#{body}</main>
      <footer class="site-footer">
        <p>© taea — <a href="https://bsky.app/profile/taea.kani.show">@taea.kani.show</a> / <a href="/feed.xml">RSS</a></p>
      </footer>
    </body>
    </html>
  HTML
end

def render_post(post)
  body = <<~HTML
    <article>
      <p class="post-date">#{post.date.strftime("%Y-%m-%d")}</p>
      <h1 class="post-title">#{CGI.escapeHTML(post.title)}</h1>
      <div class="post-body">#{post.html}</div>
    </article>
  HTML
  layout(title: "#{post.title} | #{SITE_TITLE}", body:, path: post.path)
end

def render_index(posts)
  items = posts.map { |p|
    %(<li><time>#{p.date.strftime("%Y-%m-%d")}</time><a href="#{p.path}">#{CGI.escapeHTML(p.title)}</a></li>)
  }.join("\n")
  layout(title: SITE_TITLE, body: %(<ul class="post-list">\n#{items}\n</ul>))
end

def render_feed(posts)
  items = posts.first(20).map do |p|
    <<~ITEM
      <item>
        <title>#{CGI.escapeHTML(p.title)}</title>
        <link>#{p.url}</link>
        <guid>#{p.url}</guid>
        <pubDate>#{p.date.to_time.rfc822}</pubDate>
        <description><![CDATA[#{p.html}]]></description>
      </item>
    ITEM
  end.join
  <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel>
      <title>#{SITE_TITLE}</title>
      <link>#{SITE_URL}</link>
      <description>taea の日記</description>
      #{items}
    </channel></rss>
  XML
end

# --- build ---
posts = (load_posts + load_esa_posts).sort_by(&:date).reverse
FileUtils.rm_rf(DIST)
FileUtils.mkdir_p(DIST)

posts.each do |post|
  dir = File.join(DIST, "posts", post.slug)
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "index.html"), render_post(post))
end

File.write(File.join(DIST, "index.html"), render_index(posts))
File.write(File.join(DIST, "feed.xml"), render_feed(posts))
File.write(File.join(DIST, "404.html"),
           layout(title: "404 | #{SITE_TITLE}", body: %(<p>そんな日はまだ来てないか、もう流れちまったかだ。<a href="/">一覧に戻る</a>)))
FileUtils.cp_r(File.join(ROOT, "assets"), DIST)
FileUtils.cp_r(File.join(ROOT, "images"), DIST) if Dir.exist?(File.join(ROOT, "images"))

puts "✅ build 完了: 記事 #{posts.size} 件 → dist/（画像 #{Dir.glob(File.join(ROOT, "images", "*")).size} 点）"
