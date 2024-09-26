# frozen_string_literal: true

module Codeowners
  module Import
    class Organization
      def initialize(client, storage)
        @client = client
        @storage = storage
      end

      def call(org, debug)
        response = client.fetch(org, debug)
        pp response
        org = client.org(response)
        users = client.org_members(response)
        users = client.users(response)
        teams = client.teams(response)
        memberships = client.team_members(response)

        storage.transaction do |db|
          db[:orgs].upsert(org)
          db[:users].upsert(users)
          db[:teams].upsert(teams)
          db[:memberships].upsert(memberships)
        end
      end

      private

      attr_reader :client
      attr_reader :storage
    end
  end
end
