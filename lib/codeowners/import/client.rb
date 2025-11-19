# frozen_string_literal: true

require "json"
require "excon"

module Codeowners
  module Import
    class Client
      BASE_URL = "https://api.github.com"
      private_constant :BASE_URL

      USER_AGENT = "codeowners v#{Codeowners::VERSION}"
      private_constant :USER_AGENT

      def initialize(token, out, base_url = BASE_URL, user_agent = USER_AGENT, client = Excon, sleep_time: 3)
        @base_url = base_url
        @user_agent = user_agent
        @token = token
        @client = client
        @out = out
        @sleep_time = sleep_time
      end

      def org(login, debug = false)
        result = get("/orgs/#{login}", debug: debug)

        {
          id: result.fetch("id"),
          login: result.fetch("login")
        }
      end

      def org_members(org, debug = false)
        result = get_paginated("/orgs/#{org.fetch(:login)}/members", debug: debug)
        result.map do |user|
          {
            id: user.fetch("id"),
            login: user.fetch("login")
          }
        end
      end

      def teams(org, debug = false)
        result = get_paginated("/orgs/#{org.fetch(:login)}/teams", debug: debug)
        result.map do |team|
          {
            id: team.fetch("id"),
            org_id: org.fetch(:id),
            name: team.fetch("name"),
            slug: team.fetch("slug")
          }
        end
      end

      def team_members(org, teams, debug = false)
        teams.each_with_object([]) do |team, memo|
          result = get_paginated("/orgs/#{org.fetch(:login)}/teams/#{team.fetch(:slug)}/members", debug: debug)
          result.each do |member|
            team_id = team.fetch(:id)
            user_id = member.fetch("id")

            memo << {
              id: [team_id, user_id],
              team_id: team_id,
              user_id: user_id
            }
          end

          sleep_for_a_while
        end
      end

      def users(users, debug)
        users.each do |user|
          remote_user = get("/users/#{user.fetch(:login)}", debug: debug)
          user.merge!(
            name: remote_user.fetch("name"),
            email: remote_user.fetch("email")
          )

          sleep_for_a_while
        end
      end

      def fetch_org_data(org_login, debug = false)
        out.puts "requesting GraphQL query for organization: #{org_login}" if debug

        # Fetch organization info and members
        org_data = nil
        all_users = []
        members_cursor = nil

        loop do
          query = build_org_members_query(org_login, members_cursor)
          response = graphql_query(query, debug)

          data = response.dig("data", "organization")
          break unless data

          # Extract organization data (only on first iteration)
          if org_data.nil?
            org_data = {
              id: data.fetch("id"),
              login: data.fetch("login")
            }
          end

          # Extract members
          members_page = data.dig("membersWithRole", "edges") || []
          members_page.each do |edge|
            node = edge["node"]
            all_users << {
              id: node.fetch("id"),
              login: node.fetch("login"),
              name: node["name"] || "",
              email: node["email"] || ""
            }
          end

          members_page_info = data.dig("membersWithRole", "pageInfo") || {}
          members_cursor = members_page_info["endCursor"]
          members_has_next = members_page_info["hasNextPage"] || false

          break unless members_has_next
          sleep_for_a_while
        end

        # Fetch teams with their members
        all_teams = []
        all_memberships = []
        teams_cursor = nil

        loop do
          query = build_org_teams_query(org_login, teams_cursor)
          response = graphql_query(query, debug)

          data = response.dig("data", "organization")
          break unless data

          teams_page = data.dig("teams", "edges") || []
          teams_page.each do |edge|
            team_node = edge["node"]
            team_id = team_node.fetch("id")
            team_slug = team_node.fetch("slug")

            all_teams << {
              id: team_id,
              org_id: org_data.fetch(:id),
              name: team_node.fetch("name"),
              slug: team_slug,
              blacklisted: false
            }

            # Extract team members from this page
            team_members = team_node.dig("members", "edges") || []
            team_members.each do |member_edge|
              member_node = member_edge["node"]
              all_memberships << {
                id: [team_id, member_node.fetch("id")],
                team_id: team_id,
                user_id: member_node.fetch("id")
              }
            end

            # Handle team members pagination
            team_members_page_info = team_node.dig("members", "pageInfo") || {}
            team_members_cursor = team_members_page_info["endCursor"]
            team_members_has_next = team_members_page_info["hasNextPage"] || false

            # Fetch additional team members pages if needed
            while team_members_has_next
              team_query = build_team_members_query(org_login, team_slug, team_members_cursor)
              team_response = graphql_query(team_query, debug)
              team_data = team_response.dig("data", "organization", "team")

              break unless team_data

              team_members_page = team_data.dig("members", "edges") || []
              team_members_page.each do |member_edge|
                member_node = member_edge["node"]
                all_memberships << {
                  id: [team_id, member_node.fetch("id")],
                  team_id: team_id,
                  user_id: member_node.fetch("id")
                }
              end

              team_members_page_info = team_data.dig("members", "pageInfo") || {}
              team_members_cursor = team_members_page_info["endCursor"]
              team_members_has_next = team_members_page_info["hasNextPage"] || false

              sleep_for_a_while if team_members_has_next
            end
          end

          teams_page_info = data.dig("teams", "pageInfo") || {}
          teams_cursor = teams_page_info["endCursor"]
          teams_has_next = teams_page_info["hasNextPage"] || false

          break unless teams_has_next
          sleep_for_a_while
        end

        {
          org: org_data,
          users: all_users,
          teams: all_teams,
          memberships: all_memberships
        }
      end

      private

      attr_reader :base_url
      attr_reader :user_agent
      attr_reader :token
      attr_reader :client
      attr_reader :out
      attr_reader :sleep_time

      def get(path, debug: false)
        out.puts "requesting GET #{path}" if debug

        response = client.get(base_url + path, query: query, headers: headers)
        return {} unless response.status == 200

        JSON.parse(response.body)
      end

      def get_paginated(path, result = [], debug: false, page: 1)
        out.puts "requesting GET #{path}, page: #{page}" if debug

        response = client.get(base_url + path, query: query(page: page), headers: headers)
        return [] unless response.status == 200

        parsed = JSON.parse(response.body)
        result.push(parsed)

        if parsed.any?
          sleep_for_a_while
          get_paginated(path, result, debug: debug, page: page + 1)
        else
          result.flatten
        end
      end

      def query(options = {})
        { page: 1, per_page: 100 }.merge(options)
      end

      def headers
        {
          "Authorization" => "token #{token}",
          "User-Agent" => user_agent
        }
      end

      def sleep_for_a_while
        sleep(sleep_time)
      end

      def graphql_query(query, debug = false)
        out.puts "GraphQL query: #{query}" if debug

        response = client.post(
          "#{base_url}/graphql",
          body: JSON.generate({ query: query }),
          headers: graphql_headers
        )

        return {} unless response.status == 200

        parsed = JSON.parse(response.body)
        if parsed["errors"]
          out.puts "GraphQL errors: #{parsed['errors']}" if debug
          raise "GraphQL query failed: #{parsed['errors']}"
        end

        parsed
      end

      def graphql_headers
        headers.merge(
          "Content-Type" => "application/json",
          "Accept" => "application/vnd.github.v4+json"
        )
      end

      def build_org_members_query(org_login, cursor)
        cursor_arg = cursor ? %(after: "#{cursor}") : ""

        <<~GRAPHQL
          query {
            organization(login: "#{org_login}") {
              id
              login
              membersWithRole(first: 100 #{cursor_arg}) {
                pageInfo {
                  hasNextPage
                  endCursor
                }
                edges {
                  node {
                    id
                    login
                    name
                    email
                  }
                }
              }
            }
          }
        GRAPHQL
      end

      def build_org_teams_query(org_login, cursor)
        cursor_arg = cursor ? %(after: "#{cursor}") : ""

        <<~GRAPHQL
          query {
            organization(login: "#{org_login}") {
              teams(first: 100 #{cursor_arg}) {
                pageInfo {
                  hasNextPage
                  endCursor
                }
                edges {
                  node {
                    id
                    name
                    slug
                    members(first: 100) {
                      pageInfo {
                        hasNextPage
                        endCursor
                      }
                      edges {
                        node {
                          id
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        GRAPHQL
      end

      def build_team_members_query(org_login, team_slug, cursor)
        cursor_arg = cursor ? %(after: "#{cursor}") : ""

        <<~GRAPHQL
          query {
            organization(login: "#{org_login}") {
              team(slug: "#{team_slug}") {
                members(first: 100 #{cursor_arg}) {
                  pageInfo {
                    hasNextPage
                    endCursor
                  }
                  edges {
                    node {
                      id
                    }
                  }
                }
              }
            }
          }
        GRAPHQL
      end
    end
  end
end
