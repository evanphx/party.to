# Run using "rackup -p 4567 app.ru"

require 'rubygems'
require 'sinatra'
require 'twilio'
require 'thread'
require 'pp'

CallerID = "+14068380327"

Twilio.connect "AC3ef7e0ae57a87f5fb649f37a0f5e5d18", "6b3ab9255da1ac23a2c96d2c54e48ed9"

class PartyGoer
  def initialize(number)
    @number = number
    @last_call = nil
    @just_called = nil
  end

  attr_reader :number, :last_call

  attr_accessor :just_called

  def called!
    @last_call = Time.now
  end

  def just_talked_to(b)
    @just_called == b
  end
end

class Settings
  def initialize
    @party_people = {}
    @pending = []
    @available = []
    @chill = {}
    @running = {}
  end

  attr_reader :party_people, :pending, :available, :chill, :running

  def save(file)
    File.open file, "w" do |f|
      f << Marshal.dump(self)
    end
  end

  def self.load(file)
    if File.exists?(file)
      obj = Marshal.load(File.read(file)) rescue nil
      return obj if obj
    end

    return new
  end

  def urlize(number)
    number[1..-1]
  end

  def numberize(url)
    "+#{url}"
  end

  def bridge(a,b)
    Cord.synchronize do
      a.just_called = b
      b.just_called = a

      self.pending << a
      self.pending << b
    end

    # Pick the older user to call
    if b.last_call < a.last_call
      b, a = a, b
    end

    puts "Making a call to #{a.number} to connect with #{b.number}"
    rep = Twilio::Call.make(CallerID, a.number,
                            "http://backend.party.to/bridge/#{urlize(b.number)}")

    # Any non-200
    if rep.code < 200 or rep.code > 299
      puts "Error making a call to #{a.number}: "
      p rep
      Cord.synchronize do
        self.pending.delete a
        self.pending.delete b
        self.available << b
      end
    end
  end

  def two_randoms
    possible = self.available.shuffle

    a = possible.pop

    possible.each do |b|
      jtt = a.just_talked_to(b)
      puts "Should #{a.number} call #{b.number}? #{!jtt}"

      self.available.delete(a)
      self.available.delete(b)

      return [a,b] unless jtt
    end

    self.available.delete(a)

    puts "Unable to find someone for #{a.number} to talk to, chillin' them."
    self.chill[a] = Time.now + (60 * 2)
    nil
  end
end


S = Settings.load "party.to.data"

at_exit do
  puts "Saving data.."
  S.save "party.to.data"
end

pp S

Cord = Mutex.new

ChillTime = (60 * 5)
Debounce = 5

DJ = Thread.new do
  while true
    while S.running.size < 10 and S.available.size > 1
      goers = nil
      Cord.synchronize do
        goers = S.two_randoms
      end
      S.bridge *goers if goers
    end

    sleep 2
  end
end

ChillDJ = Thread.new do
  while true
    Cord.synchronize do
      done = []
      S.chill.each do |goer, time|
        if time < Time.now
          puts "#{goer.number} is done chillin', back to the party!"
          S.available << goer
          done << goer
        end
      end

      done.each { |g| S.chill.delete(g) }
    end
    sleep 2
  end

end

Langs = ["en", "es", "fr", "de" ]
Limits = ([30] * 2) + ([60] * 10) + ([120] * 5) + ([180,240] * 3) + ([300, 360, 420] * 2)


Thread.abort_on_exception = true

class PartyTo < Sinatra::Base
  get '/' do
    "Why are you here party person?"
  end

  post '/call' do
    from = params["From"]
    status = params["CallStatus"]

    # US phone numbers only!
    if from.index("+1") == 0 and from.size == 12
      unless goer = S.party_people[from]
        S.party_people[from] = goer = PartyGoer.new(from)
      end

      if goer.last_call and goer.last_call >= Time.now - Debounce
        puts "Ignoring #{from}, debounced"
      else
        Cord.synchronize do
          if S.available.include?(goer)
            puts "#{from} is a quitter!"
            S.available.delete(goer)
          elsif S.chill.key?(goer)
            puts "#{from} was chillin' and wants to leave the party now!"
            S.chill.delete(goer)
          elsif S.pending.include?(goer)
            puts "Weird. We're calling #{from} right now..."
            S.pending.delete goer
            S.available << goer
          else
            puts "#{from} is calling us! Wants to party!"
            S.available << goer
          end
        end
      end

      goer.called!
    end

    <<-XML
<?xml version="1.0" encoding="UTF-8" ?>  
<Response> 
    <Reject reason="busy"/>
</Response>
    XML
  end

  post "/bridge/:to" do |to|
    from = params["Called"]
    to = S.numberize(to)

    cohort = S.party_people[to]

    Cord.synchronize do
      S.running[from] = cohort
      S.pending.delete S.party_people[from]
      S.pending.delete cohort
    end

    limit = Limits[rand(Limits.size)]

    if limit < 60
      time = limit
      unit = "seconds"
    else
      time = (limit / 60)
      unit = (time == 1 ? "minute" : "minutes")
    end

    puts "Connecting #{from} to #{to} for #{time} #{unit}"

    <<-XML
<?xml version="1.0" encoding="UTF-8" ?>  
<Response>
    <Say language="#{Langs[rand(Langs.size)] || 'en'}" voice="woman">Welcome to party to party.</Say>
    <Say language="en" voice="woman">Party is now being initialized. You have #{time} #{unit}.</Say>
    <Dial action="http://backend.party.to/party_started/#{S.urlize(from)}/#{S.urlize(to)}"
          timeLimit="#{limit}"
          hangupOnStar="true"
          callerId="#{CallerID}"
      >#{cohort.number}</Dial>
</Response>
XML
  end

  post "/party_started/:from/:to" do |from,to|
    from = S.numberize(from)
    to = S.numberize(to)

    error = false
    if params["DialCallStatus"] != "completed"
      error = true
      puts "Error calling #{from} => #{to}"
    end

    Cord.synchronize do
      if cohort = S.running.delete(from)
        puts "Placing #{from} and #{to} in the chill zone."

        S.chill[cohort] = Time.now + ChillTime
        S.chill[S.party_people[from]] = Time.now + ChillTime
      else
        puts "Weird, #{from} isn't actually partying. Loser."
      end
    end

    if error
      <<-XML
<?xml version="1.0" encoding="UTF-8" ?>  
<Response> 
    <Say>Sorry bro, we couldn't get the party started.</Say>
    <Hangup/>
</Response>
      XML
    else
      <<-XML
<?xml version="1.0" encoding="UTF-8" ?>  
<Response> 
    <Say>Thanks for partying!</Say>
    <Hangup/>
</Response>
      XML
    end
  end
end

run PartyTo
