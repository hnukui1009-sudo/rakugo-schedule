#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open-uri"
require "time"
require "uri"

ROOT = File.expand_path("..", __dir__)
PERFORMERS_PATH = File.join(ROOT, "performers.json")
EVENTS_PATH = File.join(ROOT, "events.json")
BASE_URL = "https://www.rakugo-kyokai.jp"
SOURCE_URL = "#{BASE_URL}/members"
USER_AGENT = "CodexRakugoSchedule/1.0"

CATEGORIES = [
  { path: "/members", label: "真打", status: "active" },
  { path: "/members/k", label: "講談", status: "active" },
  { path: "/members/f", label: "二ツ目", status: "active" },
  { path: "/members/z", label: "前座", status: "active" },
  { path: "/members/i", label: "色物", status: "active" },
  { path: "/members/o", label: "お囃子", status: "active" },
  { path: "/members/b", label: "物故者", status: "deceased" }
].freeze

def fetch(url)
  URI.open(url, "User-Agent" => USER_AGENT, read_timeout: 30, open_timeout: 30, &:read)
end

def decode_next_stream(html)
  chunks = html.scan(/self\.__next_f\.push\(\[1,"(.*?)"\]\)<\/script>/m).flatten
  return html if chunks.empty?

  chunks.map { |chunk| JSON.parse(%("#{chunk}")) }.join
end

def category_pages(html)
  pages = html.scan(/href="[^"]*\?p=(\d+)"/).flatten.map(&:to_i)
  max_page = [1, *pages].max
  (1..max_page).to_a
end

def extract_member_paths(html)
  html.scan(%r{href="(/members/[a-z0-9]+)"})
    .flatten
    .select { |path| path.split("/").last.length > 1 }
    .uniq
end

def extract_json_object(source, marker)
  marker_index = source.index(marker)
  raise "marker not found: #{marker}" unless marker_index

  start_index = source.index("{", marker_index)
  raise "object start not found for #{marker}" unless start_index

  depth = 0
  in_string = false
  escaped = false

  source.chars.each_with_index do |char, index|
    next if index < start_index

    if in_string
      if escaped
        escaped = false
      elsif char == "\\"
        escaped = true
      elsif char == "\""
        in_string = false
      end
      next
    end

    if char == "\""
      in_string = true
      next
    end

    if char == "{"
      depth += 1
    elsif char == "}"
      depth -= 1
      if depth.zero?
        return source[start_index..index]
      end
    end
  end

  raise "object end not found for #{marker}"
end

def strip_html(html)
  return nil if html.nil? || html.empty?

  text = html
    .gsub(%r{<br\s*/?>}i, "\n")
    .gsub(%r{</p>}i, "\n")
    .gsub(%r{<[^>]+>}, "")
    .gsub("&nbsp;", " ")
    .gsub("&amp;", "&")
    .gsub("&lt;", "<")
    .gsub("&gt;", ">")
    .strip

  text.empty? ? nil : text
end

def compact_hash(hash)
  hash.each_with_object({}) do |(key, value), compacted|
    next if value.nil?
    next if value.respond_to?(:empty?) && value.empty?

    compacted[key] = value
  end
end

def normalize_name(name)
  name.to_s.gsub(/[[:space:]\u3000]/, "")
end

def build_performer_record(raw, category_label, category_path, status)
  display_name = [raw["teigo"], raw["geimei"]].compact.join(" ").strip
  display_name_kana = [raw["teigo_furi"], raw["geimei_furi"]].compact.join(" ").strip
  career = Array(raw["geireki_list"]).map do |item|
    compact_hash(
      date: item["date"],
      dateFormat: item["date_format"],
      content: strip_html(item["content"])
    )
  end
  prizes = Array(raw["prize_list"]).map do |item|
    compact_hash(
      date: item["date"],
      dateFormat: item["date_format"],
      content: strip_html(item["content"])
    )
  end

  compact_hash(
    id: raw["id"],
    displayName: display_name,
    normalizedName: normalize_name(display_name),
    geimei: raw["geimei"],
    teigo: raw["teigo"],
    displayNameKana: display_name_kana,
    realName: raw["show_real_name"] ? raw["real_name"] : nil,
    realNameKana: raw["show_real_name"] ? raw["real_name_furi"] : nil,
    ranks: raw["mibun"],
    category: category_label,
    categoryPath: category_path,
    status: status,
    birthDate: raw["birth_day"],
    birthDateFormat: raw["birth_format"],
    birthPlace: raw["birth_place"],
    debayashi: raw["debayashi"],
    crest: raw["mon"],
    keyword: raw["keyword"],
    websiteURL: raw["link_website"],
    profileURL: "#{BASE_URL}/members/#{raw["id"]}",
    photoURL: raw.dig("photo", "url"),
    sourceUpdatedAt: raw["updatedAt"],
    sourcePublishedAt: raw["publishedAt"],
    shortBio: strip_html(raw["pr"]),
    publications: strip_html(raw["publications"]),
    careerHighlights: career,
    prizeHighlights: prizes
  )
end

def collect_member_index
  all_paths = []
  member_category = {}

  CATEGORIES.each do |category|
    first_html = fetch("#{BASE_URL}#{category[:path]}")
    category_pages(first_html).each do |page|
      url = page == 1 ? "#{BASE_URL}#{category[:path]}" : "#{BASE_URL}#{category[:path]}?p=#{page}"
      html = page == 1 ? first_html : fetch(url)
      extract_member_paths(html).each do |path|
        all_paths << path
        member_category[path] ||= category
      end
      sleep 0.12
    end
  end

  [all_paths.uniq, member_category]
end

def build_performers
  member_paths, member_category = collect_member_index

  performers = member_paths.map do |path|
    detail_url = "#{BASE_URL}#{path}"
    html = decode_next_stream(fetch(detail_url))
    id = path.split("/").last
    raw_json = extract_json_object(html, %("data":{"id":"#{id}"))
    raw = JSON.parse(raw_json)
    category = member_category.fetch(path)
    sleep 0.12
    build_performer_record(raw, category[:label], category[:path], category[:status])
  rescue StandardError => e
    warn "failed to parse #{detail_url}: #{e.message}"
    nil
  end.compact

  performers.sort_by { |performer| [performer["status"], performer["category"], performer["displayName"]] }
end

def write_performers_json(performers)
  payload = {
    "sourceName" => "落語協会",
    "sourceURL" => SOURCE_URL,
    "fetchedAt" => Time.now.iso8601,
    "count" => performers.length,
    "performers" => performers
  }

  File.write(PERFORMERS_PATH, JSON.pretty_generate(payload))
  payload
end

def update_events_json(performers_payload)
  events_payload = JSON.parse(File.read(EVENTS_PATH))
  performer_list = Array(performers_payload["performers"] || performers_payload[:performers])
  performer_by_name = performer_list.each_with_object({}) do |performer, hash|
    normalized_name = performer["normalizedName"] || performer[:normalizedName]
    performer_id = performer["id"] || performer[:id]
    next unless normalized_name && performer_id

    hash[normalized_name] = performer_id
  end

  events_payload["performerDirectoryUpdatedAt"] = performers_payload["fetchedAt"] || performers_payload[:fetchedAt]
  events_payload["events"] = Array(events_payload["events"]).map do |event|
    performer_ids = Array(event["performers"]).map do |name|
      performer_by_name[normalize_name(name)]
    end.compact.uniq

    event.merge("performerIds" => performer_ids)
  end

  File.write(EVENTS_PATH, JSON.pretty_generate(events_payload))
end

performers_payload = write_performers_json(build_performers)
update_events_json(performers_payload)

puts "performers.json: #{performers_payload["count"]} performers"
puts "events.json: performerIds updated"
