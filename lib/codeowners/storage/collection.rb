# frozen_string_literal: true

module Codeowners
  class Storage
    class Collection
      def initialize(collection)
        @collection = collection.each_with_object({}) do |record, memo|
          memo[record.fetch("id")] = record
        end
      end

      def find(&blk)
        collection.values.find(&blk)
      end

      def find_all(&blk)
        collection.values.find_all(&blk)
      end

      def upsert(*records)
        records = Array(records).flatten

        records.each do |record|
          collection[record.fetch(:id)] = collection[record.fetch(:id)].transform_keys!(&:to_sym).merge(record)
        end
      end

      def dump
        collection.values.dup
      end

      private

      attr_reader :collection
    end
  end
end
