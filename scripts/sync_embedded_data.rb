#!/usr/bin/env ruby
# frozen_string_literal: true

ROOT = File.expand_path("..", __dir__)
INDEX_PATH = File.join(ROOT, "index.html")
EVENTS_PATH = File.join(ROOT, "events.json")
PERFORMERS_PATH = File.join(ROOT, "performers.json")

html = File.read(INDEX_PATH)
events = File.read(EVENTS_PATH)
performers = File.read(PERFORMERS_PATH)

html = html.sub(
  %r{<script id="embedded-events" type="application/json">.*?</script>}m,
  "<script id=\"embedded-events\" type=\"application/json\">\n#{events}\n    </script>"
)

if html.include?('id="embedded-performers"')
  html = html.sub(
    %r{<script id="embedded-performers" type="application/json">.*?</script>}m,
    "<script id=\"embedded-performers\" type=\"application/json\">\n#{performers}\n    </script>"
  )
else
  html = html.sub(
    '    <script src="./app.js"></script>',
    "    <script id=\"embedded-performers\" type=\"application/json\">\n#{performers}\n    </script>\n    <script src=\"./app.js\"></script>"
  )
end

File.write(INDEX_PATH, html)

puts "embedded data synced"
