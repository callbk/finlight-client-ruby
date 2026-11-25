# frozen_string_literal: true

require "json"

# Access to the vendored contract kit in conformance/.
module Kit
  ROOT = File.expand_path("../..", __dir__)
  DIR = File.join(ROOT, "conformance")
  KEY = "sk_0000000000000000000000000000000000000000000000000000000000000001"
  # Plain lists that read as [] when their key is absent (no presence meaning). Every other absent
  # key must decode to nil, never to [] or false (R-MODELS-1).
  LIST_DEFAULTS = %w[media countries categories isins listings].freeze

  module_function

  def load(rel)
    JSON.parse(File.read(File.join(DIR, rel), encoding: "UTF-8"))
  end

  # [[case id, file name], ...] for every fixture of a kit folder, sorted by case id.
  def fixtures(folder, exclude: [])
    Dir.glob(File.join(DIR, folder, "*.json")).filter_map do |path|
      name = File.basename(path)
      next if exclude.include?(name)

      [load(File.join(folder, name)).fetch("id", name), name]
    end.sort
  end

  def case_ids
    File.read(File.join(DIR, "conformance.md")).scan(/^\| ([A-Z]-\d+) \|/).flatten
  end

  def case_titles
    File.read(File.join(DIR, "conformance.md")).scan(/^\| ([A-Z]-\d+) \| ([^|]+) \|/).to_h { |id, t| [id, t.strip] }
  end

  def snake(name)
    name.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase
  end

  def snake_args(args)
    args.to_h { |k, v| [snake(k).to_sym, v] }
  end

  # Presence state of a wire path, read from a decoded model: absent, null, empty or value.
  # Also checks that each wire key landed on the member of the same (snake_case) name.
  def presence(model, path)
    parent = model
    parts = path.split(".")
    parts.each_with_index do |part, i|
      m = /\A([A-Za-z]+)(?:\[(\d+)\])?\z/.match(part) or raise "bad path #{path}"
      name = m[1]
      index = m[2]
      member = snake(name).to_sym
      raise "#{parent.class} has no member for #{name}" unless parent.class.members.include?(member)

      value = parent.public_send(member)
      absent = !parent.raw_json.key?(name)
      if absent && !value.nil? && !(value == [] && LIST_DEFAULTS.include?(name))
        raise "#{name} is absent on the wire, but member #{member} holds #{value.inspect}"
      end

      state = if absent then "absent"
              elsif value.nil? then "null"
              elsif value == [] then "empty"
              else "value"
              end
      raw = parent.raw_json[name]
      if state == "value" && !raw.is_a?(Hash) && !raw.is_a?(Array) && value != raw
        raise "#{name}: member #{member} holds #{value.inspect}, wire has #{raw.inspect}"
      end

      if index
        return state unless state == "value"

        value = value[index.to_i]
      end
      return state if i == parts.size - 1
      return state unless state == "value"

      parent = value
    end
  end

  # Presence of a gated top-level key through the public helpers only.
  def helper_presence(article, key)
    case key
    when "content"
      return "absent" unless article.content_present?

      article.content.nil? ? "null" : "value"
    when "sentiment"
      return "absent" unless article.sentiment_present?

      article.sentiment.nil? ? "null" : "value"
    when "companies"
      return "absent" unless article.companies_present?

      article.companies.empty? ? "empty" : "value"
    when "events"
      return "absent" unless article.events_present?

      article.events.empty? ? "empty" : "value"
    end
  end
end
