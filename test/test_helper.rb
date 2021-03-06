# frozen_string_literal: true

# Configure Rails Environment
ENV['RAILS_ENV'] = 'test'

# start coverage
require 'simplecov'
SimpleCov.start

require File.expand_path('../test/dummy/config/environment.rb', __dir__)
ActiveRecord::Migrator.migrations_paths = [File.expand_path('../test/dummy/db/migrate', __dir__)]
ActiveRecord::Migrator.migrations_paths << File.expand_path('../db/migrate', __dir__)
require 'rails/test_help'
require 'mocha/mini_test'

DatabaseCleaner.strategy = :transaction

module ActiveSupport
  class TestCase
    if ActiveSupport::TestCase.respond_to?(:fixture_path=)
      self.fixture_path = File.expand_path('dummy/test/fixtures', __dir__)
      self.fixture_path = ActiveSupport::TestCase.fixture_path
      self.file_fixture_path = ActiveSupport::TestCase.fixture_path + '/files'
      fixtures :all
    end

    def setup
      DatabaseCleaner.start
    end

    def after_teardown
      DatabaseCleaner.clean
    end

    # create a confirmed email user
    def create_authed_applicant(user = applicants(:one))
      user.save!
      user
    end

    # create admin user
    def create_authed_admin(admin = admins(:one))
      admin.save!
      admin
    end

    # format request body according to JSONAPI expectations
    def xhr_req(params = {}, headers = {}, is_post = true)
      body = is_post ? { data: params }.to_json : { data: params }.to_query
      {
        params: body,
        headers: headers.merge(
          CONTENT_TYPE: 'application/json'
        )
      }
    end

    # format a JSONAPI request by an authenticated user.
    # a new confirmed user is created and used unless one is provided
    def auth_xhr_req(params = {}, user = nil, is_post = true)
      user ||= create_authed_user
      xhr_req(params, user.create_new_auth_token, is_post)
    end

    # format a multipart/form-data request by an authenticated user.
    # a new confirmed user is created and used unless one is provided
    def auth_multipart_req(params, user = nil)
      user ||= create_authed_user
      multipart_req(params, user.create_new_auth_token)
    end

    def format_response
      resp = ::JSON.parse(response.body)
      ActiveSupport::HashWithIndifferentAccess.new(resp)
                                              .deep_symbolize_keys
    end
  end
end
