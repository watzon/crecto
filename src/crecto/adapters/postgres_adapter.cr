require "pg"
require "pool/connection"

module Crecto
  module Adapters

    #
    # Adapter module for PostgresSQL
    #
    # Uses [crystal-pg](https://github.com/will/crystal-pg) for now.
    #
    # Other adapters should follow this same pattern
    module Postgres
      ENV["DB_POOL_CAPACITY"] ||= "25"
      ENV["DB_POOL_TIMEOUT"] ||= "0.01"

      DB = ConnectionPool.new(ENV["DB_POOL_CAPACITY"].to_i, ENV["DB_POOL_TIMEOUT"].to_f) do
        PG.connect(ENV["PG_URL"])
      end

      #
      # Query data store using a *query*
      #
      def self.execute(operation : Symbol, queryable, query : Crecto::Repo::Query)
        connection = DB.checkout()

        result = case operation
        when :all
          all(connection, queryable, query)
        end

        DB.checkin(connection)
        result
      end

      #
      # Query data store using an *id*, returning a single record.
      #
      def self.execute(operation : Symbol, queryable, id : Int32 | Int64 | String)
        connection = DB.checkout()

        result = case operation
        when :get
          get(connection, queryable, id)
        end

        DB.checkin(connection)
        result
      end

      # Query data store in relation to a *queryable_instance* of Schema
      def self.execute_on_instance(operation, changeset)
        connection = DB.checkout()

        result = case operation
        when :insert
          insert(connection, changeset)
        when :update
          update(connection, changeset)
        when :delete
          delete(connection, changeset)
        end

        DB.checkin(connection)
        result
      end

      private def self.get(connection, queryable, id)
        q =     ["SELECT *"]
        q.push  "FROM #{queryable.table_name}"
        q.push  "WHERE #{queryable.primary_key_field}=$1"
        q.push  "LIMIT 1"

        connection.exec(q.join(" "), [id])
      end

      private def self.all(connection, queryable, query)
        params = [] of DbValue | Array(DbValue)

        q =     ["SELECT"]
        q.push  query.selects.join(", ")
        q.push  "FROM #{queryable.table_name}"
        q.push  wheres(queryable, query, params) if query.wheres.any?
        # TODO: JOINS
        q.push  order_bys(query) if query.order_bys.any?
        q.push  limit(query) unless query.limit.nil?
        q.push  offset(query) unless query.offset.nil?

        connection.exec(position_args(q.join(" ")), params)
      end

      private def self.insert(connection, changeset)
        fields_values = instance_fields_and_values(changeset.instance)

        q =     ["INSERT INTO"]
        q.push  "#{changeset.instance.class.table_name}"
        q.push  "(#{fields_values[:fields]})"
        q.push  "VALUES"
        q.push  "(#{fields_values[:values]})"
        q.push  "RETURNING *"

        connection.exec(q.join(" "))
      end

      private def self.update(connection, changeset)
        fields_values = instance_fields_and_values(changeset.instance)

        q =     ["UPDATE"]
        q.push  "#{changeset.instance.class.table_name}"
        q.push  "SET"
        q.push  "(#{fields_values[:fields]})"
        q.push  "="
        q.push  "(#{fields_values[:values]})"
        q.push  "WHERE"
        q.push  "#{changeset.instance.class.primary_key_field}=#{changeset.instance.pkey_value}"
        q.push  "RETURNING *"

        connection.exec(q.join(" "))
      end

      private def self.delete(connection, changeset)
        q =     ["DELETE FROM"]
        q.push  "#{changeset.instance.class.table_name}"
        q.push  "WHERE"
        q.push  "#{changeset.instance.class.primary_key_field}=#{changeset.instance.pkey_value}"
        q.push  "RETURNING *"

        connection.exec(q.join(" "))
      end

      private def self.wheres(queryable, query, params)
        q = ["WHERE "]
        where_clauses = [] of String

        query.wheres.each do |where|
          if where.is_a?(NamedTuple)
            where_clauses.push(add_where(where, params))
          elsif where.is_a?(Hash)
            where_clauses += add_where(where, queryable, params)
          end
        end
        
        q.push where_clauses.join(" AND ")
        q.join("")
      end

      private def self.add_where(where : NamedTuple, params)
        where[:params].each{|param| params.push(param) }
        where[:clause]
      end

      private def self.add_where(where : Hash, queryable, params)
        where.keys.map do |key|
          [where[key]].flatten.each{|param| params.push(param) }

          resp = " #{queryable.table_name}.#{key}"
          resp += if where[key].is_a?(Array)
            " IN (" + where[key].as(Array).map{|p| "?" }.join(", ") + ")"
          else
            "=?"
          end
        end
      end

      private def self.order_bys(query)
        "ORDER BY #{query.order_bys.join(", ")}"
      end

      private def self.limit(query)
        "LIMIT #{query.limit}"
      end

      private def self.offset(query)
        "OFFSET #{query.offset}"
      end

      private def self.instance_fields_and_values(queryable_instance)
        query_hash = queryable_instance.to_query_hash
        values = query_hash.values.map do |value|
          to_query_val(value)
        end
        {fields: query_hash.keys.join(", "), values: values.join(", ")}
      end

      private def self.to_query_val(val, operator = false)
        resp = if val.nil?
          "NULL"
        elsif val.is_a?(String)
          "'#{val}'"
        elsif val.is_a?(Array)
          "#{val.to_s.gsub(/^\[/, "(").gsub(/\]$/, ")").gsub(/"/, "'")}"
        elsif val.is_a?(Time)
          "'#{val.to_utc.to_s("%Y-%m-%d %H:%M:%S")}'"
        else
          "#{val}"
        end

        if operator
          op = val.is_a?(Array) ? " in " : " = "
          resp = op + resp
        end

        resp
      end

      private def self.position_args(query_string : String)
        query = ""
        chunks = query_string.split("?")
        chunks.each_with_index do |chunk, i|
          query += chunk
          query += "$#{i + 1}" unless i == chunks.size - 1
        end
        query
      end

    end
  end
end