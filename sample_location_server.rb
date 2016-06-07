#!/usr/bin/ruby1.9
require 'rubygems'
require 'sinatra'
require 'data_mapper'
require 'json'
require 'digest/sha1'

# zip content when possible
use Rack::Deflater

# ---- Parse command-line arguments ----

SECRET = ENV['SECRET']
puts "SECRET is #{SECRET}"
VALIDATOR = ENV['VALIDATOR']
puts "VALIDATOR is #{VALIDATOR}"

db = ENV['DATABASE_URL']
puts "Writing database to #{db}"

# ---- Set up the database -------------
DataMapper.setup(:default, db)

class Client
  include DataMapper::Resource

  property :id,         Serial                    # row key
  property :mac,        String,  :key => true
  property :seenString, String
  property :seenEpoch,  Integer, :default => 0, :index => true
  property :lat,        Float
  property :lng,        Float
  property :unc,        Float
  property :manufacturer, String
  property :os,         String
  property :ssid,       String
  property :floors,     String
end

DataMapper.finalize

DataMapper.auto_migrate!    # Creates your schema in the database

# ---- Set up routes -------------------

# Serve the frontend.
get '/' do
  send_file File.join(settings.public_folder, 'index.html')
end

# This is used by the Meraki API to validate this web app.
# In general it is a Bad Thing to change this.
get '/events' do
  VALIDATOR
end

# Respond to Meraki's push events. Here we're just going
# to write the most recent events to our database.
post '/events' do
  if request.media_type != "application/json"
    logger.warn "got post with unexpected content type: #{request.media_type}"
    logger.warn "body: #{request.body}"
    return
  end
  request.body.rewind
  map = JSON.parse(request.body.read)
  puts map
  if map['secret'] != SECRET
    logger.warn "got post with bad secret: #{map['secret']}"
    return
  end
  logger.info "version is #{map['version']}"
  if map['version'] != '2.0'
    logger.warn "got post with unexpected version: #{map['version']}"
    return
  end
  if map['type'] != 'DevicesSeen'
    logger.warn "got post for event that we're not interested in: #{map['type']}"
    return
  end
  map['data']['observations'].each do |c|
    loc = c['location']
    next if loc == nil
    name = c['clientMac']
    lat = loc['lat']
    lng = loc['lng']
    seenString = c['seenTime']
    seenEpoch = c['seenEpoch']
    floors = map['data']['apFloors'] == nil ? "" : map['data']['apFloors'].join
    logger.info "AP #{map['data']['apMac']} on #{map['data']['apFloors']}: #{c}"
    next if (seenEpoch == nil || seenEpoch == 0)  # This probe is useless, so ignore it
    client = Client.first_or_create(:mac => name)
    if (seenEpoch > client.seenEpoch)             # If client was created, this will always be true
      client.attributes = { :lat => lat, :lng => lng,
                            :seenString => seenString, :seenEpoch => seenEpoch,
                            :unc => loc['unc'],
                            :manufacturer => c['manufacturer'], :os => c['os'],
                            :ssid => c['ssid'],
                            :floors => floors
                          }
      client.save
    end
  end
  ""
end

# Serve client data from the database.

# This matches
#    /clients/<mac>
# and returns a client with a given mac address, or empty JSON
# if the mac is not in the database.
get '/clients/:mac' do |m|
  name = m.sub "%20", " "
  puts "Request name is #{name}"
  content_type :json
  client = Client.first(:mac => name)
  logger.info("Retrieved client #{client}")
  client != nil ? JSON.generate(client) : "{}"
end

# This matches
#   /clients OR /clients/
# and returns a JSON blob of all clients.
get %r{/clients/?} do
  content_type :json
  clients = Client.all(:seenEpoch.gt => (Time.new - 300).to_i)
  JSON.generate(clients)
end
