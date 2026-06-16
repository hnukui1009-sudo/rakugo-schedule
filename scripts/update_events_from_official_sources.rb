#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "date"
require "json"
require "open-uri"
require "time"
require "uri"

ROOT = ENV["RAKUGO_ROOT"] || File.expand_path("..", __dir__)
RAW_BASE = ENV["RAKUGO_RAW_BASE"] || "https://raw.githubusercontent.com/hnukui1009-sudo/rakugo-schedule/main"
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

def ascii_url(url)
  url.to_s.each_char.map { |char| char.ascii_only? ? char : CGI.escape(char).gsub("+", "%20") }.join
end

def read_text(path, fallback_url: nil)
  return File.read(path) if File.exist?(path)
  return fetch(fallback_url) if fallback_url

  raise "Missing file: #{path}"
end

def decode_next_stream(html)
  chunks = html.scan(/self\.__next_f__\.push\(\[1,\"(.*?)\"\]\)<\/script>/m).flatten
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
  name.to_s.gsub(/[[:space:]\u3000]/, "")
end

def area_from(venue, address)
  text = [venue, address].compact.join(" ")
  {
    /上野/ => "上野",
    /浅草/ => "浅草",
    /新宿/ => "新宿",
    /銀座|東銀座/ => "銀座",
    /池袋/ => "池袋",
    /渋谷/ => "渋谷",
    /深川|江東/ => "江東",
    /墨田|トリフォニー/ => "墨田",
    /仙台/ => "仙台",
    /水戸/ => "水戸",
    /さいたま/ => "埼玉",
    /京都|南座/ => "京都",
    /博多|福岡/ => "博多",
    /大阪|新歌舞伎座/ => "大阪",
    /立川/ => "立川",
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
  return "京都府" if address.match?(/京都|南座/)
  return "福岡県" if address.match?(/博多|福岡/)
  return "大阪府" if address.match?(/大阪|新歌舞伎座/)

  default
end

def parse_jp_date(text)
  match = text.to_s.match(/(\d{4})年(\d{2})月(\d{2})日/)
  return nil unless match

  Date.new(match[1].to_i, match[2].to_i, match[3].to_i)
end

def parse_jp_date_flexible(text, default_year: TODAY.year)
  match = text.to_s.match(/(?:(\d{4})年)?(\d{1,2})月(\d{1,2})日/)
  return nil unless match

  year = (match[1] || default_year).to_i
  Date.new(year, match[2].to_i, match[3].to_i)
end

def parse_jp_date_range(text, default_year: TODAY.year)
  normalized = text.to_s.gsub("〜", "～")
  start_match = normalized.match(/(?:(\d{4})年)?(\d{1,2})月(\d{1,2})日/)
  return nil unless start_match

  start_year = (start_match[1] || default_year).to_i
  start_month = start_match[2].to_i
  start_day = start_match[3].to_i
  start_date = Date.new(start_year, start_month, start_day)

  tail = normalized[(start_match.begin(0) + start_match[0].length)..]
  end_match = tail&.match(/～(?:(\d{4})年)?(?:(\d{1,2})月)?(\d{1,2})日/)
  return [start_date, start_date] unless end_match

  end_year = (end_match[1] || start_year).to_i
  end_month = (end_match[2] || start_month).to_i
  end_day = end_match[3].to_i
  [start_date, Date.new(end_year, end_month, end_day)]
end

def parse_time_text(text)
  normalized = text.to_s.tr("０-９：", "0-9:")
  return format("%<hour>02d:%<min>02d", hour: Regexp.last_match(1).to_i, min: Regexp.last_match(2).to_i) if normalized =~ /(\d{1,2})[:](\d{2})/
  return format("%<hour>02d:%<min>02d", hour: Regexp.last_match(1).to_i, min: Regexp.last_match(2).to_i) if normalized =~ /(\d{1,2})時(\d{1,2})分/
  return format("%<hour>02d:00", hour: Regexp.last_match(1).to_i) if normalized =~ /(\d{1,2})時/

  nil
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
  payload = JSON.parse(read_text(PERFORMERS_PATH, fallback_url: "#{RAW_BASE}/performers.json"))
  payload.fetch("performers", []).each_with_object({}) do |performer, hash|
    hash[performer["normalizedName"]] = performer["id"]
  end
end

def load_previous_event_map
  payload = JSON.parse(read_text(EVENTS_PATH, fallback_url: "#{RAW_BASE}/events.json"))
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

def target_month_dates
  [Date.new(TODAY.year, TODAY.month, 1), Date.new(TODAY.next_month.year, TODAY.next_month.month, 1)].uniq
end

def rakugo_kyokai_list_items(month)
  html = fetch("https://www.rakugo-kyokai.jp/rakugokai?m=#{month}")
  decoded = decode_next_stream(html)
  decoded.scan(/\"href\":\"(\/rakugokai\/[^\"]+)\".*?\"children\":\"(\d{4}年\d{2}月\d{2}日)\".*?\"children\":\"([^\"]+)\"/m)
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

  match = snippet.match(/\"children\":\"#{Regexp.escape(label)}\".*?\"children\":\"([^\"]+)\"/m)
  match && clean_value(match[1])
end

def extract_section_row(decoded, section_label, row_label)
  snippet = extract_between(decoded, section_label, limit: 5000)
  return nil unless snippet

  match = snippet.match(/\"children\":\"#{Regexp.escape(row_label)}\".*?\"children\":\"([^\"]+)\"/m)
  match && clean_value(match[1])
end

def extract_ticket_url(decoded)
  decoded[/\\\"href\\\":\\\"(https?:\/\/[^\\\"]+)\\\".*?children\\\":\\\"https?:\/\/[^\\\"]+\\\"/m, 1]
end

def extract_kyokai_performers(decoded)
  names = []

  ["出演者（協会員）", "出演者（その他）"].each do |label|
    snippet = extract_between(decoded, label, limit: 8000)
    next unless snippet

    names.concat(
      snippet.scan(/children\":\[\"([^\"]+)\",\[\"\$\",\"rt\".*?children\":\[\"([^\"]+)\",\[\"\$\",\"rt\"/m).map do |teigo, geimei|
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
    description = strip_html(html[/<meta name=\"description\" content=\"([^\"]+)\"/, 1])

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
  venue_blocks = html.scan(/<dt><img[^>]*alt=\"([^\"]+)\"[^>]*\/><\/dt>(.*?)<\/dl>/m)

  venue_blocks.flat_map do |venue, block|
    block.scan(/<dd><a href=\"([^\"]*jyoseki_detail\?id=\d+)\">([^<]+)<\/a><\/dd>/).map do |href, text|
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
  html.scan(/<a class=\"card\" href=\"([^\"]+)\">.*?<dt>([^<]+)<\/dt>.*?<span class=\"dayTxt\">([^<]+)<\/span>.*?<span class=\"title\">([^<]+)<\/span>/m).map do |href, venue, day_text, title|
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

def extract_first_text(html, *patterns)
  patterns.each do |pattern|
    match = html.match(pattern)
    value = clean_value(match[1]) if match
    return value if value
  end
  nil
end

def build_kodankyokai_events
  event_urls = target_month_dates.flat_map do |month_date|
    calendar_url = "https://kodankyokai.jp/calendar/action~month/exact_date~#{month_date.year}-#{month_date.month}-1/"
    html = fetch(calendar_url)
    html.scan(/href="([^"]+)"/).flatten.map { |href| CGI.unescapeHTML(href) }
        .select { |href| href.include?("kodankyokai.jp/") && href.include?("/イベント/") }
  end.uniq.first(30)

  event_urls.map do |url|
    normalized_url = ascii_url(url)
    html = fetch(normalized_url)
    title = clean_value(html[/<title>(.*?)<\/title>/m, 1]&.sub(/\s*[｜|].*/, "")) ||
            extract_first_text(html, /<h1[^>]*>(.*?)<\/h1>/m) ||
            "講談会"
    date_candidates = html.scan(/(\d{4}年\d{1,2}月\d{1,2}日)/).flatten
    start_date = date_candidates.map { |text| parse_jp_date_flexible(text) }.compact.find { |date| date >= TODAY }
    next unless start_date

    start_time = extract_first_text(
      html,
      /開演[^0-9]*(\d{1,2}[:：]\d{2})/m,
      /開演[^0-9]*(\d{1,2}時\d{1,2}分)/m,
      /時間[^0-9]*(\d{1,2}[:：]\d{2})/m
    )
    venue_name = extract_first_text(
      html,
      /(?:会場|場所|ところ)[^<]{0,20}<\/(?:th|dt)>\s*<(?:td|dd)[^>]*>(.*?)<\/(?:td|dd)>/m,
      /(?:会場|場所|ところ)[^:：]{0,10}[:：]\s*([^<\n]+)/m
    )
    price_text = extract_first_text(
      html,
      /(?:木戸銭|料金|入場料)[^<]{0,20}<\/(?:th|dt)>\s*<(?:td|dd)[^>]*>(.*?)<\/(?:td|dd)>/m,
      /(?:木戸銭|料金|入場料)[^:：]{0,10}[:：]\s*([^<\n]+)/m
    )
    description = strip_html(html[/<meta name="description" content="([^"]+)"/, 1]) ||
                  "#{title}の公式スケジュール掲載情報。"
    venue_text = venue_name || title

    {
      "id" => "kodankyokai-#{safe_id(url)}",
      "title" => title,
      "category" => "kodan",
      "categoryLabel" => "講談",
      "startAt" => iso_datetime(start_date, parse_time_text(start_time)),
      "endAt" => nil,
      "venueName" => venue_name,
      "venueAddress" => nil,
      "area" => area_from(venue_text, venue_text),
      "prefecture" => prefecture_from(venue_text),
      "performers" => [],
      "priceText" => price_text,
      "description" => description,
      "sourceName" => "講談協会",
      "sourceURL" => normalized_url,
      "ticketURL" => normalized_url,
      "lastConfirmedAt" => NOW.iso8601,
      "fetchedAt" => NOW.iso8601
    }.delete_if { |_, value| value.nil? || (value.respond_to?(:empty?) && value.empty?) }
  end.compact
end

def parse_toyokan_range(heading, subheading)
  range = parse_jp_date_range("#{heading} #{subheading}")
  return range if range

  single_date = parse_jp_date_flexible("#{heading} #{subheading}")
  [single_date, single_date]
end

def build_asakusa_toyokan_events
  html = fetch("https://www.asakusatoyokan.com/timetable/")
  rows = html.scan(/<th>(.*?)<\/th>\s*<td><a href="javascript:void\(0\);" onclick="javascript:void\(window\.open\('new\.php\?detail_data=([^']+)'[^"]*\)\.focus\(\)\);">\s*(.*?)<\/a>/m)

  rows.map do |heading_html, detail_id, title_html|
    heading = clean_value(heading_html)
    subheading = clean_value(heading_html[/<span>(.*?)<\/span>/m, 1])
    start_date, end_date = parse_toyokan_range(heading, subheading)
    next unless start_date && start_date >= TODAY

    title = clean_value(title_html)
    next if title&.include?("公開予定")

    detail_url = "https://www.asakusatoyokan.com/timetable/new.php?detail_data=#{detail_id}"
    detail_html = fetch(detail_url)
    price_text = extract_first_text(detail_html, /料金\s*[:：]\s*(.*?)<\/p>/m)
    open_time = parse_time_text(extract_first_text(detail_html, /開場[:：]\s*([^　<]+)/m))
    start_time = parse_time_text(extract_first_text(detail_html, /開演[:：]\s*([^　<]+)/m))
    description = extract_first_text(detail_html, /<div class="postTxt">.*?<p>(.*?)<\/p>/m) ||
                  "#{title}の公式スケジュール掲載情報。"

    {
      "id" => "toyokan-#{detail_id}",
      "title" => title,
      "category" => "toyokan",
      "categoryLabel" => "浅草東洋館",
      "startAt" => iso_datetime(start_date, start_time || open_time || "12:30"),
      "endAt" => end_date && end_date > start_date ? iso_datetime(end_date, "21:00") : nil,
      "venueName" => "浅草東洋館",
      "venueAddress" => "東京都台東区浅草1-43-12",
      "area" => "浅草",
      "prefecture" => "東京都",
      "performers" => [],
      "priceText" => price_text,
      "description" => description,
      "sourceName" => "浅草東洋館",
      "sourceURL" => detail_url,
      "ticketURL" => detail_url,
      "lastConfirmedAt" => NOW.iso8601,
      "fetchedAt" => NOW.iso8601
    }.delete_if { |_, value| value.nil? || (value.respond_to?(:empty?) && value.empty?) }
  end.compact
end

def build_kabuki_events
  html = fetch("https://www.kabuki-bito.jp/schedule")
  cards = html.split('<span class="label type-theater">')[1..].to_a.map do |segment|
    venue = clean_value(segment[/([^<]+)<\/span>/m, 1])
    href, title = segment.scan(/<a href="(\/theaters\/[^"]+\/play\/\d+)">([^<]+)<\/a>/m)
                         .map { |candidate_href, candidate_title| [candidate_href, clean_value(candidate_title)] }
                         .find { |_, candidate_title| candidate_title && !candidate_title.empty? }
    date_text = clean_value(segment[/<p class="term">\s*([^<]+)<\/p>/m, 1])
    next unless venue && href && title && date_text

    [venue, href, title, date_text]
  end.compact

  cards.map do |venue, href, title, date_text|
    start_date, end_date = parse_jp_date_range(clean_value(date_text))
    next unless start_date && start_date >= TODAY

    url = "https://www.kabuki-bito.jp#{href}"
    {
      "id" => "kabuki-#{href[%r{play/(\d+)}, 1]}",
      "title" => clean_value(title),
      "category" => "kabuki",
      "categoryLabel" => "歌舞伎",
      "startAt" => iso_datetime(start_date, "11:00"),
      "endAt" => end_date && end_date > start_date ? iso_datetime(end_date, "20:00") : nil,
      "venueName" => clean_value(venue),
      "venueAddress" => nil,
      "area" => area_from(venue, venue),
      "prefecture" => prefecture_from(venue),
      "performers" => [],
      "description" => "#{clean_value(venue)}の歌舞伎公演公式スケジュール掲載情報。",
      "sourceName" => "歌舞伎美人",
      "sourceURL" => url,
      "ticketURL" => url,
      "lastConfirmedAt" => NOW.iso8601,
      "fetchedAt" => NOW.iso8601
    }.delete_if { |_, value| value.nil? || (value.respond_to?(:empty?) && value.empty?) }
  end.compact
end

performer_map = load_performer_map
previous_event_map = load_previous_event_map
events = (
  build_rakugo_kyokai_events(performer_map) +
  build_geikyo_jyoseki_events +
  build_ntj_events +
  build_kodankyokai_events +
  build_asakusa_toyokan_events +
  build_kabuki_events
)
         .uniq { |event| event["id"] }
         .select { |event| event_date(event) && event_date(event) >= TODAY }
         .map do |event|
           previous = previous_event_map[event["id"]] || {}
           first_seen_at = previous["firstSeenAt"] || NOW.iso8601
           event.merge("firstSeenAt" => first_seen_at)
         end
         .sort_by { |event| event["startAt"] }

performer_directory_updated_at = JSON.parse(read_text(PERFORMERS_PATH, fallback_url: "#{RAW_BASE}/performers.json"))["fetchedAt"]
payload = {
  "updatedAt" => NOW.iso8601,
  "performerDirectoryUpdatedAt" => performer_directory_updated_at,
  "events" => events
}

File.write(EVENTS_PATH, JSON.pretty_generate(payload))

html = read_text(INDEX_PATH, fallback_url: "#{RAW_BASE}/index.html")
html = html.sub(
  %r{<script id="embedded-events" type="application/json">.*?</script>}m,
  "<script id=\"embedded-events\" type=\"application/json\">\n#{JSON.pretty_generate(payload)}\n    </script>"
)
File.write(INDEX_PATH, html)

puts "events.json updated: #{events.length} events"
