# frozen_string_literal: true

module Codeowners
  module Import
    class Organization
      def initialize(client, storage)
        @client = client
        @storage = storage
      end

      def call(org, debug)
        data = client.fetch_org_data(org, debug)

        storage.transaction do |db|
          db[:orgs].upsert(data[:org])
          db[:users].upsert(data[:users])
          db[:teams].upsert(data[:teams])
          db[:memberships].upsert(data[:memberships])
        end
      end

      private

      attr_reader :client
      attr_reader :storage
    end
  end
end
