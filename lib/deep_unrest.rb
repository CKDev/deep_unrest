# frozen_string_literal: true

require 'deep_unrest/engine'

# Update deeply nested associations wholesale
module DeepUnrest
  class InvalidParentScope < ::StandardError
  end

  class InvalidAssociation < ::StandardError
  end

  class InvalidPath < ::StandardError
  end

  class ValidationError < ::StandardError
  end

  class InvalidId < ::StandardError
  end

  class UnpermittedParams < ::StandardError
  end

  class Conflict < ::StandardError
  end

  class Unauthorized < ::StandardError
  end

  def self.to_class(str)
    str.classify.constantize
  end

  def self.to_assoc(str)
    str.pluralize.underscore.to_sym
  end

  def self.to_update_body_key(str)
    "#{str.pluralize}Attributes".underscore.to_sym
  end

  def self.get_resource(type)
    "#{type.classify}Resource".constantize
  end

  def self.get_scope_type(id, last, destroy)
    case id
    when /^\[\w+\]$/
      :create
    when /^\.\w+$/
      if last
        if destroy
          :destroy
        else
          :update
        end
      else
        :show
      end
    when /^\.\*$/
      if last
        if destroy
          :destroy_all
        else
          :update_all
        end
      else
        :index
      end
    else
      raise InvalidId, "Unknown ID format: #{id}"
    end
  end

  # verify that this is an actual association of the parent class.
  def self.add_parent_scope(parent, type)
    reflection = parent[:klass].reflect_on_association(to_assoc(type))
    { base: parent[:scope], method: reflection.name }
  end

  def self.validate_association(parent, type)
    return unless parent
    reflection = parent[:klass].reflect_on_association(to_assoc(type))
    raise NoMethodError unless reflection.klass == to_class(type)
    unless parent[:id]
      raise InvalidParentScope, 'Unable to update associations of collections '\
                                "('#{parent[:type]}.#{type}')."
    end
  rescue NoMethodError
    raise InvalidAssociation, "'#{parent[:type]}' has no association '#{type}'"
  end

  def self.get_scope(scope_type, memo, type, id_str = nil)
    case scope_type
    when :show, :update, :destroy
      id = /^\.(?<id>\d+)$/.match(id_str)[:id]
      { base: to_class(type), method: :find, arguments: [id] }
    when :update_all, :index
      if memo.empty?
        { base: to_class(type), method: :all }
      else
        add_parent_scope(memo[memo.size - 1], type)
      end
    # TODO: delete this condition
    when :all
      { base: to_class(type), method: :all }
    end
  end

  def self.parse_path(path)
    rx = /(?<type>\w+)(?<id>(?:\[|\.)[\w+\*\]]+)/
    result = path.scan(rx)
    unless result.map { |res| res.join('') }.join('.') == path
      raise InvalidPath, "Invalid path: #{path}"
    end
    result
  end

  def self.update_indices(indices, type)
    indices[type] ||= 0
    indices[type] += 1
    indices
  end

  def self.parse_attributes(type, scope_type, attributes, user)
    p = JSONAPI::RequestParser.new
    resource = get_resource(type)
    p.resource_klass = resource
    ctx = { current_user: user }
    opts = if scope_type == :create
             resource.creatable_fields(ctx)
           else
             resource.updatable_fields(ctx)
           end

    p.parse_params({ attributes: attributes }, opts)[:attributes]
  rescue JSONAPI::Exceptions::ParametersNotAllowed
    unpermitted_keys = attributes.keys.map(&:to_sym) - opts
    msg = "Attributes #{unpermitted_keys} of #{type.classify} not allowed"
    msg += " to #{user.class} with id '#{user.id}'" if user
    raise UnpermittedParams, [{ title: msg }].to_json
  end

  def self.collect_action_scopes(operation)
    resources = parse_path(operation[:path])
    resources.each_with_object([]) do |(type, id), memo|
      validate_association(memo.last, type)
      scope_type = get_scope_type(id,
                                  memo.size == resources.size - 1,
                                  operation[:destroy])
      scope = get_scope(scope_type, memo, type, id)
      context = { type: type,
                  scope_type: scope_type,
                  scope: scope,
                  klass: to_class(type),
                  id: id }

      context[:path] = operation[:path] unless scope_type == :show
      memo.push(context)
    end
  end

  def self.collect_all_scopes(params)
    idx = {}
    params.map { |operation| collect_action_scopes(operation) }
          .flatten
          .uniq
          .map do |op|
            unless op[:scope_type] == :show
              op[:index] = update_indices(idx, op[:type])[op[:type]] - 1
            end
            op
          end
  end

  def self.parse_id(id_str)
    id_match = id_str.match(/^\.(?<id>\d+)$/)
    id_match && id_match[:id]
  end

  def self.set_action(cursor, operation, type, user)
    # TODO: this is horrible. find a better way to go about this
    action = get_scope_type(parse_path(operation[:path]).last[1],
                            true,
                            operation[:destroy])

    case action
    when :destroy
      cursor[:_destroy] = true
    when :update, :create, :update_all
      cursor.merge! parse_attributes(type,
                                     operation[:action],
                                     operation[:attributes],
                                     user)
    end
    cursor
  end

  def self.get_mutation_cursor(memo, cursor, addr, type, id, destroy)
    if memo
      cursor[addr] = [{}]
      next_cursor = cursor[addr][0]
    else
      cursor = {}
      type_sym = type.to_sym
      if destroy
        method = id ? :update : :destroy_all
      else
        method = id ? :update : :update_all
      end
      klass = to_class(type)
      body = {}
      body[klass.primary_key.to_sym] = id if id
      cursor[type_sym] = {
        klass: klass
      }
      cursor[type_sym][:operations] = {}
      cursor[type_sym][:operations][id] = {}
      cursor[type_sym][:operations][id][method] = {
        method: method,
        body: body
      }
      memo = cursor
      next_cursor = cursor[type_sym][:operations][id][method][:body]
    end
    [memo, next_cursor]
  end

  def self.build_mutation_fragment(op, user, rest = nil, memo = nil, cursor = nil, type = nil)
    rest ||= parse_path(op[:path])

    if rest.empty?
      set_action(cursor, op, type, user)
      return memo
    end

    type, id_str = rest.shift
    addr = to_update_body_key(type)
    id = parse_id(id_str)

    memo, next_cursor = get_mutation_cursor(memo, cursor, addr, type, id, op[:destroy])

    next_cursor[:id] = id if id
    build_mutation_fragment(op, user, rest, memo, next_cursor, type)
  end

  def self.build_mutation_body(ops, user)
    ops.each_with_object({}) do |op, memo|
      memo.deeper_merge(build_mutation_fragment(op, user))
    end
  end

  def self.mutate(mutation, user)
    mutation.map do |_, item|
      item[:operations].map do |id, ops|
        ops.map do |_, action|
          case action[:method]
          when :update_all
            DeepUnrest.authorization_strategy
                      .get_authorized_scope(user, item[:klass])
                      .update(action[:body])
            nil
          when :destroy_all
            DeepUnrest.authorization_strategy
                      .get_authorized_scope(user, item[:klass])
                      .destroy_all
            nil
          when :update
            item[:klass].update(id, action[:body])
          when :create
            item[:klass].create(action[:body])
          end
        end
      end
    end
  end

  def self.parse_error_path(key)
    rx = /(((^|\.)(?<type>[^\.\[]+)(?:\[(?<idx>\d+)\])\.)?(?<field>[\w\.]+)$)/
    rx.match(key)
  end

  def self.format_errors(operation, path_info, values)
    if operation
      return values.map do |msg|
        { title: "#{path_info[:field].humanize} #{msg}",
          detail: msg,
          source: { pointer: "#{operation[:path]}.#{path_info[:field]}" } }
      end
    end
    values.map do |msg|
      { title: msg, detail: msg, source: { pointer: nil } }
    end
  end

  def self.map_errors_to_param_keys(scopes, ops)
    ops.map do |errors|
      errors.map do |key, values|
        path_info = parse_error_path(key.to_s)
        operation = scopes.find do |s|
          s[:type] == path_info[:type] && s[:index] == path_info[:idx].to_i
        end

        format_errors(operation, path_info, values)
      end
    end.flatten
  end

  def self.perform_update(params, user)
    # identify requested scope(s)
    scopes = collect_all_scopes(params)

    # authorize user for requested scope(s)
    DeepUnrest.authorization_strategy.authorize(scopes, user).flatten

    # bulid update arguments
    mutations = build_mutation_body(params, user)

    # perform update
    results = mutate(mutations, user).flatten

    # check results for errors
    errors = results.compact
                    .map(&:errors)
                    .map(&:messages)
                    .reject(&:empty?)
                    .compact

    return if errors.empty?

    # map errors to their sources
    formatted_errors = { errors: map_errors_to_param_keys(scopes, errors) }

    # raise error if there are any errors
    raise Conflict, formatted_errors.to_json unless formatted_errors.empty?
  end
end
