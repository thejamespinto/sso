module SSO
  module Server
    module Doorkeeper
      class AccessTokenMarker
        include ::SSO::Logging

        attr_reader :request, :response
        delegate :params, to: :request

        def initialize(app)
          @app = app
        end

        def call(env)
          @env = env
          @request = ::ActionDispatch::Request.new @env
          @response = @app.call @env

          return response unless applicable?

          if authorization_grant_flow?
            handle_authorization_grant_flow
          elsif password_flow?
            handle_password_flow
          else
            fail NotImplementedError
          end

          response
        end

        def applicable?
          request.method == 'POST' &&
            (authorization_grant_flow? || password_flow?) &&
            response_code == 200 &&
            response_body &&
            outgoing_access_token
        end

        def handle_authorization_grant_flow
          # We cannot rely on looking up session[:passport_id] here because the end-user might have cookies disabled.
          # The only thing we can really rely on to identify the Passport is the incoming grant token.
          debug { %(Detected outgoing "Access Token" #{outgoing_access_token.inspect} of the "Authorization Code Grant" flow) }
          debug { %(This Access Token belongs to "Authorization Grant Token" #{grant_token.inspect}. Augmenting related Passport with it...) }
          registration = ::SSO::Server::Passports.register_access_token_from_grant grant_token: grant_token, access_token: outgoing_access_token

          return if registration.success?
          warn { 'The passport could not be augmented via the authorizaton grant. Destroying warden session.' }
          warden.logout
        end

        def handle_password_flow
          local_passport_id = session[:passport_id] # <- We know this always exists because it was set in this very response
          debug { %(Detected outgoing "Access Token" #{outgoing_access_token.inspect} of the "Resource Owner Password Credentials Grant" flow.) }
          debug { %(Augmenting local Passport #{local_passport_id.inspect} with this outgoing Access Token...) }
          registration = ::SSO::Server::Passports.register_access_token_from_id passport_id: local_passport_id, access_token: outgoing_access_token

          return if registration.success?
          warn { 'The passport could not be augmented via the access token. Destroying warden session.' }
          warden.logout
        end

        def response_body
          response.last.first.presence
        end

        def response_code
          response.first
        end

        def parsed_response_body
          return unless response_body
          ::JSON.parse response_body
        rescue JSON::ParserError => exception
          Trouble.notify exception
          nil
        end

        def outgoing_access_token
          return unless parsed_response_body
          parsed_response_body['access_token']
        end

        def warden
          request.env['warden']
        end

        def authorization_grant_flow?
          grant_token.present?
        end

        def password_flow?
          grant_type == 'password'
        end

        def grant_token
          params['code']
        end

        def grant_type
          params['grant_type']
        end

        def session
          @env['rack.session']
        end

      end
    end
  end
end
