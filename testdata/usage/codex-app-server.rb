#!/usr/bin/ruby
# Read-only Codex protocol fixture. All files belong to a temporary test profile.
require 'json'
profile = ENV.fetch('CODEX_HOME')
STDOUT.sync = true
STDIN.each_line do |line|
  request = JSON.parse(line)
  File.open(File.join(profile, 'requests.jsonl'), 'a') { |f| f.puts(JSON.generate(request)) }
  next unless request.key?('id')
  response = { 'id' => request['id'] }
  case request['method']
  when 'initialize'
    response['result'] = {}
  when 'account/read'
    response['result'] = { 'account' => JSON.parse(File.read(File.join(profile, 'account.json'))) }
  when 'account/rateLimits/read'
    value = JSON.parse(File.read(File.join(profile, 'rates.json')))
    if value.key?('error')
      response['error'] = value['error']
    else
      response['result'] = value
    end
  else
    response['error'] = { 'code' => -32601, 'message' => 'Unexpected fixture method' }
  end
  puts JSON.generate(response)
end
