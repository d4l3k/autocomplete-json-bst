require 'bundler'
Bundler.require
require 'json'

class TestFile
  attr_reader :rows_per_hit

  def initialize
    @words = []
    if ARGV.empty?
      @words += File.read('/usr/share/dict/cracklib-small').split("\n")
    else
      ARGV.each do |arg|
        text = File.read(arg)
        sanitized = text.unpack('C*').reject {|a| a >= 128}.pack('C*')
        @words += sanitized.split("\n")
      end
    end
    @words.map! do |word|
      word.split('/').first
    end
    @words.uniq!
    @words.compact!
    @words.sort!

    # Attempt to emulate the number of hits required for a 5M uniq row dataset
    @rows_per_hit = (1000.0 / 5000000 * @words.count).floor

    # Attempt to emulate server request lag
    @lag = 0.2

    max_hits = Math.log2(@words.length / @rows_per_hit).ceil

    puts "WORDS: #{@words.length}, LAG: #{@lag}, RPH: #{@rows_per_hit}, MAX_HITS: #{max_hits}"
  end
  def count dataset
    @words.count
  end
  def get_words dataset, offset
    sleep @lag
    @words[offset, rows_per_hit]
  end
end

class SoqlAdapter
  attr_reader :rows_per_hit
  def initialize
    @rows_per_hit = 1000
  end
  def count dataset
    Thread.current[:curl] ||= Curl::Easy.new
    c = Thread.current[:curl]
    c.url = "http://data.cityofchicago.org/resource/#{dataset}.json?$query=select%20count(*)"
    c.perform
    JSON.parse(c.body_str)[0]['count'].to_i
  end
  def get_words dataset, offset
    Thread.current[:curl] ||= Curl::Easy.new
    c = Thread.current[:curl]
    c.url = URI.encode("http://data.cityofchicago.org/resource/#{dataset}.json?$query=select case_number GROUP BY case_number ORDER BY case_number ASC OFFSET #{offset}")
    c.perform
    JSON.parse(c.body_str).map do |obj|
      obj['case_number']
    end
  end
end


$dataService = SoqlAdapter.new

$cache = {}

helpers do
  def cache_get_words dataset, dataOffset
    $cache[dataset] ||= {}
    data = $cache[dataset][dataOffset]
    puts "ATTEMPT HIT #{dataset} #{dataOffset}"
    if data.nil?
      data = $dataService.get_words(dataset, dataOffset)
      $cache[dataset][dataOffset] = data
      cached = false
    else
      cached = true
    end
    [data, cached]
  end
  def get_suggestions dataset, start
    if start.empty?
      return cache_get_words(dataset, 0)[0]
    end
    start = start.downcase
    count = $dataService.count(dataset)
    found = []
    blockSize = count/(2.0 * $dataService.rows_per_hit)
    hits = 0
    attempted_hits = 0
    offset = blockSize
    prevMatch = []
    foundStart = false
    while blockSize >= 0.5 && offset.floor * $dataService.rows_per_hit < count
      dataOffset = offset.floor * $dataService.rows_per_hit
      words, cached = cache_get_words(dataset, dataOffset)
      hits += 1 unless cached
      attempted_hits += 1
      if words.empty?
        dir = -1
      elsif !foundStart && start < words.first[0...start.length].downcase && dataOffset > 0
        dir = -1
      # Edge case where first word is the only one.
      elsif !foundStart && start == words.first[0...start.length].downcase && dataOffset > 0
        dir = -1
        if blockSize < 4
          words.each do |word|
            if word[0...start.length].downcase == start
              prevMatch.push(word)
            end
          end
        end
      elsif start > words.last[0...start.length].downcase
        if !prevMatch.empty?
          found += prevMatch
        else
          dir = 1
        end
      else
        words.each do |word|
          if word[0...start.length].downcase == start
            found.push(word)
          end
        end
        if found.length == 0
          break
        end
      end
      if found.empty?
        blockSize /= 2
        offset += dir * blockSize
      elsif foundStart
        break
      else
        offset += 1
        foundStart = true
      end
    end
    logger.info "HITS A: #{attempted_hits}, M: #{hits}"
    found.sort
  end
end

get '/complete/:dataset/:start?' do
  JSON.dump(get_suggestions(params[:dataset], params[:start] || ''))
end
get '/' do
  erb :index
end
