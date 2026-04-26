#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "json"
require "open-uri"
require "time"
require "uri"

ROOT = File.expand_path("..", __dir__)
EVENTS_PATH = File.join(ROOT, "events.json")
PERFORMERS_PATH = File.join(ROOT, "performers.json")
INDEX_PATH = File.join(ROOT, "index.html")
USER_AGENT = "CodexRakugoSchedule/1.0"
TZ = "+09:00"
NOW = Time.now.getlocal(TZ)
TODAY = NOW.to_date

def fetch(url)
  URI.open(url, "User-Agent" => USER_AGENT, read_timeout: 30, open_timeout: 30, &:read)
end

def decode_next_stream(html)
  chunks = html.scan(/self\.__next_f\.push\(\[1,"(.*?)"\]\)<\/script>/m).flatten
  return html if chunks.empty?

  chunks.map { |chunk| JSON.parse(%("#{chunk}")) }.join
end

def strip_html(text)
  return nil if text.nil?

  text
    .gsub(%r{<br\s*/?>}i, "\n")
    .gsub(%r{</p>}i, "\n")
    .gsub(%r{<[^>]+>}, "")
    .gsub("&nbsp;", " ")
    .gsub("&amp;", "&")
    .gsub("&lt;", "<")
    .gsub("&gt;", ">")
    .strip
end

def clean_value(value)
  cleaned = strip_html(value)
  return nil if cleaned.nil? || cleaned.empty? || cleaned == "$undefined"

  cleaned
end

def normalize_name(name)
  name.to_s.gsub(/[[:space:]　]/, "")
end

def area_from(venue, address)
  text = [venue, address].compact.join(" ")
  {
    /上野/ => "上野",
    /浅草/ => "浅草",
    /新宿/ => "新宿",
    /池袋/ => "池袋",
    /渋谷/ => "渋谷",
    /深川|江東/ => "江東",
    /墨田|トリフォニー/ => "墨田",
    /仙台/ => "仙台",
    /水戸/ => "水戸",
    /さいたま/ => "埼玉",
    /大田区/ => "大田区",
    /文京/ => "文京区"
  }.each do |pattern, area|
    return area if text.match?(pattern)
  end
  nil
end

def prefecture_from(address, default: "東京都")
  return default if address.nil? || address.empty?

  return "神奈川県" if address.match?(/横浜|神奈川/)
  return "埼玉県" if address.match?(/埼玉/)
  return "栃木県" if address.match?(/栃木|小山/)
  return "茨城県" if address.match?(/水戸|茨城/)
  return "宮城県" if address.match?(/仙台|宮城/)

  default
end

def parse_jp_date(text)
  match = text.match(/(\d{4})年(\d{2})月(\d{2})日/)
  return nil unless match

  Date.new(match[1].to_i, match[2].to_i, match[3].to_i)
end

def iso_datetime(date, time_text = nil)
  time_value = time_text && time_text.match?(/\A\d{1,2}:\d{2}\z/) ? time_text : "12:00"
  hour, min = time_value.split(":").map(&:to_i)
  format("%<date>sT%<hour>02d:%<min>02d:00%<tz>s", date: date.strftime("%Y-%m-%d"), hour: hour, min: min, tz: TZ)
end

def event_date(event)
  Date.parse(event.fetch("startAt"))
rescue StandardError
  nil
end

def safe_id(text)
  text.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")
end

def load_performer_map
  payload = JSON.parse(File.read(PERFORMERS_PATH))
  payload.fetch("performers", []).each_with_object({}) do |performer, hash|
    hash[performer["normalizedName"]] = performer["id"]
  end
end

def load_previous_event_map
  return {} unless File.exist?(EVENTS_PATH)

  payload = JSON.parse(File.read(EVENTS_PATH))
  Array(payload["events"]).each_with_object({}) do |event, hash|
    hash[event["id"]] = event
  end
rescue StandardError
  {}
end

def map_performer_ids(names, performer_map)
  Array(names).map { |name| performer_map[normalize_name(name)] }.compact.uniq
end

def target_months
  [TODAY, TODAY.next_month].map { |date| date.strftime("%Y%m") }.uniq
end

def rakugo_kyokai_list_items(month)
  html = fetch("https://www.rakugo-kyokai.jp/rakugokai?m=#{month}")
  decoded = decode_next_stream(html)
  decoded.scan(/"href":"(\/rakugokai\/[^"]+)".*?"children":"(\d{4}年\d{2}月\d{2}日)".*?"children":"([^"]+)"/m)
    .map { |path, date_text, title| { path: path, date: parse_jp_date(date_text), title: title } }
    .select { |item| item[:path] !~ /entry/ && item[:date] && item[:date] >= TODAY }
    .uniq { |item| item[:path] }
end

def extract_between(decoded, label, limit: 1500)
  idx = decoded.index(%("children":"#{label}"))
  return nil unless idx

  decoded[idx, limit]
end

def extract_first_value(decoded, label)
  snippet = extract_between(decoded, label)
  return nil unless snippet

  match = snippet.match(/"children":"#{Regexp.escape(label)}".*?"children":"([^"]+)"/m)
  match && clean_value(match[1])
end

def extract_section_row(decoded, section_label, row_label)
  snippet = extract_between(decoded, section_label, limit: 5000)
  return nil unless snippet

  match = snippet.match(/"children":"#{Regexp.escape(row_label)}".*?"children":"([^"]+)"/m)
  match && clean_value(match[1])
end

def extract_ticket_url(decoded)
  decoded[/\"href\":\"(https?:\/\/[^\"]+)\".*?children\":\"https?:\/\/[^\"]+\"/m, 1]
end

def extract_kyokai_performers(decoded)
  names = []

  ["出演者（協会員）", "出演者（その他）"].each do |label|
    snippet = extract_between(decoded, label, limit: 8000)
    next unless snippet

    names.concat(
      snippet.scan(/children":\["([^"]+)",\["\$","rt".*?children":\["([^"]+)",\["\$","rt"/m).map do |teigo, geimei|
        "#{teigo} #{geimei}"
      end
    )
  end

  names.map { |name| name.gsub(/\s+/, " ").strip }
       .reject(&:empty?)
       .uniq
       .reject { |name| name.match?(/\A(出演者|協会員|その他)\z/) }
end

def category_for_title(title)
  return ["dokuenkai", "独演会"] if title.include?("独演会")
  return ["hall", "ホール落語"] if title.include?("花形演芸会") || title.include?("立川流落語会")

  ["rakugokai", "落語会"]
end

def build_rakugo_kyokai_events(performer_map)
  items = target_months.flat_map { |month| rakugo_kyokai_list_items(month) }
          .uniq { |item| item[:path] }
          .sort_by { |item| item[:date] }
          .first(30)

  items.map do |item|
    url = "https://www.rakugo-kyokai.jp#{item[:path]}"
    html = fetch(url)
    decoded = decode_next_stream(html)
    title = html[/<title>(.*?) \| 落語会情報/, 1] || item[:title]
    start_date = parse_jp_date(extract_first_value(decoded, "開催日")) || item[:date]
    open_time = extract_first_value(decoded, "開場時間")
    start_time = extract_first_value(decoded, "開演時間")
    venue_name = extract_section_row(decoded, "会場", "名称")
    venue_address = extract_section_row(decoded, "会場", "住所")
    performers = extract_kyokai_performers(decoded)
    category, category_label = category_for_title(title)
    price_parts = []
    %w[前　売 当　日 その他].each do |label|
      value = extract_section_row(decoded, "木戸銭", label)
      price_parts << "#{label}: #{value}" if value
    end
    description = strip_html(html[/<meta name="description" content="([^"]+)"/, 1])

    {
      "id" => "rakugo-kyokai-#{safe_id(item[:path])}",
      "title" => title,
      "category" => category,
      "categoryLabel" => category_label,
      "startAt" => iso_datetime(start_date, start_time),
      "endAt" => nil,
      "venueName" => venue_name,
      "venueAddress" => venue_address,
      "area" => area_from(venue_name, venue_address),
      "prefecture" => prefecture_from(venue_address),
      "performers" => performers,
      "performerIds" => map_performer_ids(performers, performer_map),
      "priceText" => price_parts.join(" / "),
      "description" => description,
      "sourceName" => "落語協会",
      "sourceURL" => url,
      "ticketURL" => extract_ticket_url(decoded) || url,
      "lastConfirmedAt" => NOW.iso8601,
      "fetchedAt" => NOW.iso8601
    }.delete_if { |_, value| value.nil? || (value.respond_to?(:empty?) && value.empty?) }
  end
end

GEIKYO_VENUE_AREA = {
  "新宿末廣亭" => "新宿",
  "浅草演芸ホール" => "浅草",
  "池袋演芸場" => "池袋",
  "国立演芸場" => "都心",
  "お江戸上野広小路亭" => "上野",
  "花座（仙台）" => "仙台"
}.freeze

def build_geikyo_jyoseki_events
  html = fetch("https://www.geikyo.com/index.php/schedule/index")
  venue_blocks = html.scan(/<dt><img[^>]*alt="([^"]+)"[^>]*\/><\/dt>(.*?)<\/dl>/m)

  venue_blocks.flat_map do |venue, block|
    block.scan(/<dd><a href="([^"]*jyoseki_detail\?id=\d+)">([^<]+)<\/a><\/dd>/).map do |href, text|
      date_match = text.match(/(\d+)月(\d+)日(?:〜|～)(\d+)日/)
      next unless date_match

      month = date_match[1].to_i
      start_day = date_match[2].to_i
      end_day = date_match[3].to_i
      year = month >= TODAY.month ? TODAY.year : TODAY.year + 1
      start_date = Date.new(year, month, start_day)
      next if start_date < TODAY

      end_date = Date.new(year, month, end_day)
      {
        "id" => "geikyo-jyoseki-#{href[/id=(\d+)/, 1]}",
        "title" => "#{venue} #{text.gsub(/\s+/, ' ').strip}",
        "category" => "yose",
        "categoryLabel" => "寄席",
        "startAt" => iso_datetime(start_date, "12:00"),
        "endAt" => iso_datetime(end_date, "20:30"),
        "venueName" => venue,
        "area" => GEIKYO_VENUE_AREA[venue],
        "prefecture" => venue.include?("仙台") ? "宮城県" : "東京都",
        "performers" => [],
        "description" => "落語芸術協会の定席スケジュール掲載情報。",
        "sourceName" => "落語芸術協会",
        "sourceURL" => href.start_with?("http") ? href : "https://www.geikyo.com#{href}",
        "ticketURL" => href.start_with?("http") ? href : "https://www.geikyo.com#{href}",
        "lastConfirmedAt" => NOW.iso8601,
        "fetchedAt" => NOW.iso8601
      }
    end
  end.compact
end

def convert_reiwa_date(text)
  text.gsub("令和8年", "2026年")
end

def build_ntj_events
  html = fetch("https://www.ntj.jac.go.jp/engei/")
  html.scan(/<a class="card" href="([^"]+)">.*?<dt>([^<]+)<\/dt>.*?<span class="dayTxt">([^<]+)<\/span>.*?<span class="title">([^<]+)<\/span>/m).map do |href, venue, day_text, title|
    date_text = convert_reiwa_date(day_text)
    date_match = date_text.match(/(\d{4})年(\d+)月(\d+)日(?:（[^）]+）)?(?:～(\d+)日)?/)
    next unless date_match

    year = date_match[1].to_i
    month = date_match[2].to_i
    start_day = date_match[3].to_i
    end_day = (date_match[4] || start_day).to_i
    start_date = Date.new(year, month, start_day)
    next if start_date < TODAY

    end_date = Date.new(year, month, end_day)
    {
      "id" => "ntj-#{safe_id(href)}",
      "title" => title,
      "category" => "hall",
      "categoryLabel" => "ホール落語",
      "startAt" => iso_datetime(start_date, "13:00"),
      "endAt" => iso_datetime(end_date, "16:00"),
      "venueName" => venue,
      "area" => area_from(venue, venue),
      "prefecture" => "東京都",
      "performers" => [],
      "description" => "国立演芸場主催公演の公式スケジュール掲載情報。",
      "sourceName" => "国立演芸場",
      "sourceURL" => href.start_with?("http") ? href : "https://www.ntj.jac.go.jp/#{href.sub(%r{\A/}, '')}",
      "ticketURL" => href.start_with?("http") ? href : "https://www.ntj.jac.go.jp/#{href.sub(%r{\A/}, '')}",
      "lastConfirmedAt" => NOW.iso8601,
      "fetchedAt" => NOW.iso8601
    }
  end.compact
end

performer_map = load_performer_map
previous_event_map = load_previous_event_map
events = (build_rakugo_kyokai_events(performer_map) + build_geikyo_jyoseki_events + build_ntj_events)
         .uniq { |event| event["id"] }
         .select { |event| event_date(event) && event_date(event) >= TODAY }
         .map do |event|
           previous = previous_event_map[event["id"]] || {}
           first_seen_at = previous["firstSeenAt"] || NOW.iso8601
           event.merge(
             "firstSeenAt" => first_seen_at
           )
         end
         .sort_by { |event| event["startAt"] }

payload = {
  "updatedAt" => NOW.iso8601,
  "performerDirectoryUpdatedAt" => JSON.parse(File.read(PERFORMERS_PATH))["fetchedAt"],
  "events" => events
}

File.write(EVENTS_PATH, JSON.pretty_generate(payload))

if File.exist?(INDEX_PATH)
  html = File.read(INDEX_PATH)
  html = html.sub(
    %r{<script id="embedded-events" type="application/json">.*?</script>}m,
    "<script id=\"embedded-events\" type=\"application/json\">\n#{JSON.pretty_generate(payload)}\n    </script>"
  )
  File.write(INDEX_PATH, html)
end

puts "events.json updated: #{events.length} events"
