# frozen_string_literal: true

module DiscourseAi
  module AiBot
    class ToolRunner
      attr_reader :tool, :parameters, :llm
      attr_accessor :running_attached_function, :timeout, :custom_raw

      TooManyRequestsError = Class.new(StandardError)

      DEFAULT_TIMEOUT = 2000
      MAX_MEMORY = 10_000_000
      MARSHAL_STACK_DEPTH = 20
      MAX_HTTP_REQUESTS = 20

      def initialize(parameters:, llm:, bot_user:, context: {}, tool:, timeout: nil)
        @parameters = parameters
        @llm = llm
        @bot_user = bot_user
        @context = context
        @tool = tool
        @timeout = timeout || DEFAULT_TIMEOUT
        @running_attached_function = false

        @http_requests_made = 0
      end

      def mini_racer_context
        @mini_racer_context ||=
          begin
            ctx =
              MiniRacer::Context.new(
                max_memory: MAX_MEMORY,
                marshal_stack_depth: MARSHAL_STACK_DEPTH,
              )
            attach_truncate(ctx)
            attach_http(ctx)
            attach_index(ctx)
            attach_upload(ctx)
            attach_chain(ctx)
            ctx.eval(framework_script)
            ctx
          end
      end

      def framework_script
        http_methods = %i[get post put patch delete].map { |method| <<~JS }.join("\n")
          #{method}: function(url, options) {
            return _http_#{method}(url, options);
          },
          JS
        <<~JS
        const http = {
          #{http_methods}
        };

        const llm = {
          truncate: _llm_truncate,
        };

        const index = {
          search: _index_search,
        }

        const upload = {
          create: _upload_create,
        }

        const chain = {
          setCustomRaw: _chain_set_custom_raw,
        };

        function details() { return ""; };
      JS
      end

      def details
        eval_with_timeout("details()")
      end

      def eval_with_timeout(script, timeout: nil)
        timeout ||= @timeout
        mutex = Mutex.new
        done = false
        elapsed = 0

        t =
          Thread.new do
            begin
              while !done
                # this is not accurate. but reasonable enough for a timeout
                sleep(0.001)
                elapsed += 1 if !self.running_attached_function
                if elapsed > timeout
                  mutex.synchronize { mini_racer_context.stop unless done }
                  break
                end
              end
            rescue => e
              STDERR.puts e
              STDERR.puts "FAILED TO TERMINATE DUE TO TIMEOUT"
            end
          end

        rval = mini_racer_context.eval(script)

        mutex.synchronize { done = true }

        # ensure we do not leak a thread in state
        t.join
        t = nil

        rval
      ensure
        # exceptions need to be handled
        t&.join
      end

      def invoke
        mini_racer_context.eval(tool.script)
        eval_with_timeout("invoke(#{JSON.generate(parameters)})")
      rescue MiniRacer::ScriptTerminatedError
        { error: "Script terminated due to timeout" }
      end

      private

      MAX_FRAGMENTS = 200

      def rag_search(query, filenames: nil, limit: 10)
        limit = limit.to_i
        return [] if limit < 1
        limit = [MAX_FRAGMENTS, limit].min

        upload_refs =
          UploadReference.where(target_id: tool.id, target_type: "AiTool").pluck(:upload_id)

        if filenames
          upload_refs = Upload.where(id: upload_refs).where(original_filename: filenames).pluck(:id)
        end

        return [] if upload_refs.empty?

        query_vector = DiscourseAi::Embeddings::Vector.instance.vector_from(query)
        fragment_ids =
          DiscourseAi::Embeddings::Schema
            .for(RagDocumentFragment)
            .asymmetric_similarity_search(query_vector, limit: limit, offset: 0) do |builder|
              builder.join(<<~SQL, target_id: tool.id, target_type: "AiTool")
                rag_document_fragments ON
                  rag_document_fragments.id = rag_document_fragment_id AND
                  rag_document_fragments.target_id = :target_id AND
                  rag_document_fragments.target_type = :target_type
              SQL
            end
            .map(&:rag_document_fragment_id)

        fragments =
          RagDocumentFragment.where(id: fragment_ids, upload_id: upload_refs).pluck(
            :id,
            :fragment,
            :metadata,
          )

        mapped = {}
        fragments.each do |id, fragment, metadata|
          mapped[id] = { fragment: fragment, metadata: metadata }
        end

        fragment_ids.take(limit).map { |fragment_id| mapped[fragment_id] }
      end

      def attach_truncate(mini_racer_context)
        mini_racer_context.attach(
          "_llm_truncate",
          ->(text, length) { @llm.tokenizer.truncate(text, length) },
        )
      end

      def attach_index(mini_racer_context)
        mini_racer_context.attach(
          "_index_search",
          ->(*params) do
            begin
              query, options = params
              self.running_attached_function = true
              options ||= {}
              options = options.symbolize_keys
              self.rag_search(query, **options)
            ensure
              self.running_attached_function = false
            end
          end,
        )
      end

      def attach_chain(mini_racer_context)
        mini_racer_context.attach("_chain_set_custom_raw", ->(raw) { self.custom_raw = raw })
      end

      def attach_upload(mini_racer_context)
        mini_racer_context.attach(
          "_upload_create",
          ->(filename, base_64_content) do
            begin
              self.running_attached_function = true
              # protect against misuse
              filename = File.basename(filename)

              Tempfile.create(filename) do |file|
                file.binmode
                file.write(Base64.decode64(base_64_content))
                file.rewind

                upload =
                  UploadCreator.new(
                    file,
                    filename,
                    for_private_message: @context[:private_message],
                  ).create_for(@bot_user.id)

                { id: upload.id, short_url: upload.short_url, url: upload.url }
              end
            ensure
              self.running_attached_function = false
            end
          end,
        )
      end

      def attach_http(mini_racer_context)
        mini_racer_context.attach(
          "_http_get",
          ->(url, options) do
            begin
              @http_requests_made += 1
              if @http_requests_made > MAX_HTTP_REQUESTS
                raise TooManyRequestsError.new("Tool made too many HTTP requests")
              end

              self.running_attached_function = true
              headers = (options && options["headers"]) || {}

              result = {}
              DiscourseAi::AiBot::Tools::Tool.send_http_request(url, headers: headers) do |response|
                result[:body] = response.body
                result[:status] = response.code.to_i
              end

              result
            ensure
              self.running_attached_function = false
            end
          end,
        )

        %i[post put patch delete].each do |method|
          mini_racer_context.attach(
            "_http_#{method}",
            ->(url, options) do
              begin
                @http_requests_made += 1
                if @http_requests_made > MAX_HTTP_REQUESTS
                  raise TooManyRequestsError.new("Tool made too many HTTP requests")
                end

                self.running_attached_function = true
                headers = (options && options["headers"]) || {}
                body = options && options["body"]

                result = {}
                DiscourseAi::AiBot::Tools::Tool.send_http_request(
                  url,
                  method: method,
                  headers: headers,
                  body: body,
                ) do |response|
                  result[:body] = response.body
                  result[:status] = response.code.to_i
                end

                result
              rescue => e
                p url
                p options
                p e
                puts e.backtrace
                raise e
              ensure
                self.running_attached_function = false
              end
            end,
          )
        end
      end
    end
  end
end
