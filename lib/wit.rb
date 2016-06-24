require 'json'
require 'logger'
require 'net/http'
require 'securerandom'

WIT_API_HOST = ENV['WIT_URL'] || 'https://api.wit.ai'
DEFAULT_MAX_STEPS = 5
LEARN_MORE = 'Learn more at https://wit.ai/docs/quickstart'

class WitException < Exception
end

def req(access_token, meth_class, path, params={}, payload={})
  uri = URI(WIT_API_HOST + path)
  uri.query = URI.encode_www_form(params)

  logger.debug("#{meth_class} #{uri}")

  request = meth_class.new(uri)
  request['authorization'] = 'Bearer ' + access_token
  request['accept'] = 'application/vnd.wit.20160330+json'
  request.add_field 'Content-Type', 'application/json'
  request.body = payload.to_json

  Net::HTTP.start(uri.host, uri.port, {:use_ssl => uri.scheme == 'https'}) do |http|
    rsp = http.request(request)
    if rsp.code.to_i != 200
      raise WitException.new("HTTP error code=#{rsp.code}")
    end
    json = JSON.parse(rsp.body)
    if json.has_key?('error')
      raise WitException.new("Wit responded with an error: #{json['error']}")
    end
    logger.debug("#{meth_class} #{uri} #{json}")
    json
  end
end

def validate_actions(actions)
  [:send].each do |action|
    if !actions.has_key?(action)
      Wit.logger.warn "The #{action} action is missing. #{LEARN_MORE}"
    end
  end
  actions.each_pair do |k, v|
    Wit.logger.warn "The '#{k}' action name should be a symbol" unless k.is_a? Symbol
    Wit.logger.warn "The '#{k}' action should be a lambda function" unless v.respond_to?(:call) && v.lambda?
    Wit.logger.warn "The \'send\' action should take 2 arguments: request and response. #{LEARN_MORE}" if k == :send && v.arity != 2
    Wit.logger.warn "The '#{k}' action should take 1 argument: request. #{LEARN_MORE}" if k != :send && v.arity != 1
  end
  return actions
end

class Wit
  def initialize(opts = {})
    @access_token = opts[:access_token]

    if opts[:actions]
      @actions = validate_actions(opts[:actions])
    end

    if opts[:logger]
      @logger = opts[:logger]
    end
  end

  def logger
    @logger ||= begin
      x = Logger.new(STDOUT)
      x.level = Logger::INFO
      x
    end
  end

  def message(msg)
    params = {}
    params[:q] = msg unless msg.nil?
    res = req @access_token, Net::HTTP::Get, '/message', params
    return res
  end

  def converse(session_id, msg, context={})
    if !context.is_a?(Hash)
      raise WitException.new('context should be a Hash')
    end
    params = {}
    params[:q] = msg unless msg.nil?
    params[:session_id] = session_id
    res = req(@access_token, Net::HTTP::Post, '/converse', params, context)
    return res
  end

  def __run_actions(session_id, message, context, i)
    if i <= 0
      raise WitException.new('Max steps reached, stopping.')
    end
    json = converse(session_id, message, context)
    if json['type'].nil?
      raise WitException.new('Couldn\'t find type in Wit response')
    end

    logger.debug("Context: #{context}")
    logger.debug("Response type: #{json['type']}")

    # backwards-compatibility with API version 20160516
    if json['type'] == 'merge'
      json['type'] = 'action'
      json['action'] = 'merge'
    end

    if json['type'] == 'error'
      raise WitException.new('Oops, I don\'t know what to do.')
    end

    if json['type'] == 'stop'
      return context
    end

    request = {
      'session_id' => session_id,
      'context' => context.clone,
      'text' => message,
      'entities' => json['entities']
    }
    if json['type'] == 'msg'
      throw_if_action_missing(:send)
      response = {
        'text' => json['msg'],
        'quickreplies' => json['quickreplies'],
      }
      @actions[:send].call(request, response)
    elsif json['type'] == 'action'
      action = json['action'].to_sym
      throw_if_action_missing(action)
      context = @actions[action].call(request)
      if context.nil?
        logger.warn('missing context - did you forget to return it?')
        context = {}
      end
    else
      raise WitException.new("unknown type: #{json['type']}")
    end

    return __run_actions(session_id, nil, context, i - 1)
  end

  def run_actions(session_id, message, context={}, max_steps=DEFAULT_MAX_STEPS)
    if !@actions
      throw_must_have_actions
    end
    if !context.is_a?(Hash)
      raise WitException.new('context should be a Hash')
    end
    return __run_actions(session_id, message, context, max_steps)
  end

  def interactive(context={}, max_steps=DEFAULT_MAX_STEPS)
    if !@actions
      throw_must_have_actions
    end

    session_id = SecureRandom.uuid
    while true
      print '> '
      msg = gets.strip
      next if msg == ''

      begin
        context = run_actions(session_id, msg, context, max_steps)
      rescue WitException => exp
        logger.error("error: #{exp.message}")
      end
    end
  rescue Interrupt => _exp
    puts
  end

  def throw_if_action_missing(action_name)
    if !@actions.has_key?(action_name)
      raise WitException.new("unknown action: #{action_name}")
    end
  end

  def throw_must_have_actions()
    raise WitException.new('You must provide the `actions` parameter to be able to use runActions. ' + LEARN_MORE)
  end

  private :__run_actions
end
