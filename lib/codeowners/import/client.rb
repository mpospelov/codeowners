# frozen_string_literal: true

require "json"
require "excon"

module Codeowners
  module Import
    class Client
      BASE_URL = "https://api.github.com"
      private_constant :BASE_URL

      USER_AGENT = "codeowners v#{Codeowners::VERSION}"
      QUERY = <<~GRAPHQL
        query ($first: Int, $after: String, $org: String!) {
          organization(login: $org) {
            id: databaseId
            login
            teams(first: $first, after: $after) {
              pageInfo {
                hasNextPage
                endCursor
              }
              nodes {
                id: databaseId
                name
                slug
                members {
                  nodes {
                    id: databaseId
                    login
                    name
                    email
                  }
                }
              }
            }
          }
        }
      GRAPHQL
      private_constant :USER_AGENT

      def initialize(token, out, base_url = BASE_URL, user_agent = USER_AGENT, client = Excon, sleep_time: 3)
        @base_url = base_url
        @user_agent = user_agent
        @token = token
        @client = client
        @out = out
        @sleep_time = sleep_time
      end

      def fetch(org, debug = false)
        end_coursor = nil
        has_next_page = true
        responses = []

        while has_next_page
          response = post("/graphql", JSON.dump(query: QUERY, variables: { first: 100, after: end_coursor, org: org }), debug: debug)
          has_next_page = response.dig("data", "organization", "teams", "pageInfo", "hasNextPage")
          end_coursor = response.dig("data", "organization", "teams", "pageInfo", "endCursor")
          responses << response
          sleep_for_a_while
        end
        result = responses[0]
        responses[1..].each do |res|
          result["data"]["organization"]["teams"]["nodes"] += res["data"]["organization"]["teams"]["nodes"]
        end
        result
      end

      def org(response)
        {
          id: response.dig("data", "organization", "id"),
          login: response.dig("data", "organization", "login")
        }
      end

      def org_members(response)
        response.dig("data", "organization", "teams", "nodes").each_with_object([]) do |team, memo|
          team.fetch("members").fetch("nodes").each do |member|
            memo << {
              id: member.fetch("id"),
              login: member.fetch("login")
            }
          end
        end.sort_by { |member| member.fetch(:id) }
      end

      def teams(response)
        response.dig("data", "organization", "teams", "nodes").map do |team|
          {
            id: team.fetch("id"),
            org_id: response.dig("data", "organization", "id"),
            name: team.fetch("name"),
            slug: team.fetch("slug")
          }
        end.sort_by { |team| team.fetch(:id) }
      end

      def team_members(response)
        response.dig("data", "organization", "teams", "nodes").each_with_object([]) do |team, memo|
          team.fetch("members").fetch("nodes").each do |member|
            team_id = team.fetch("id")
            user_id = member.fetch("id")
            memo << {
              id: [team_id, user_id],
              team_id: team_id,
              user_id: user_id
            }
          end
        end.sort_by { |member| member.fetch(:id) }
      end

      def users(response)
        response.dig("data", "organization", "teams", "nodes").each_with_object([]) do |team, memo|
          team.fetch("members").fetch("nodes").each do |member|
            memo << {
              id: member.fetch("id"),
              login: member.fetch("login"),
              name: member.fetch("name"),
              email: member.fetch("email")
            }
          end
        end.sort_by { |member| member.fetch(:id) }
      end

      private

      attr_reader :base_url
      attr_reader :user_agent
      attr_reader :token
      attr_reader :client
      attr_reader :out
      attr_reader :sleep_time

      def post(path, body, debug: false)
        out.puts "requesting POST #{path}" if debug

        response = client.post(base_url + path, body: body, headers: headers)
        return {} unless response.status == 200

        JSON.parse(response.body)
      end

      def headers
        {
          "Authorization" => "token #{token}",
          "User-Agent" => user_agent,
          "Content-Type" => "application/json"
        }
      end

      def sleep_for_a_while
        sleep(sleep_time)
      end
    end
  end
end
