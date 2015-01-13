module MultiFetchFragments
  extend ActiveSupport::Concern

  included do
    alias_method_chain :render_collection, :multi_fetch_cache
  end

  private

    delegate :instrument_fragment_cache, :cache_store, :fragment_cache_key, to: '@view.controller'

    def render_collection_with_multi_fetch_cache
      return nil if @collection.blank?

      if @options.key?(:spacer_template)
        spacer = find_template(@options[:spacer_template]).render(@view, @locals)
      end

      results = []

      if cache_collection?

        additional_cache_options = @options[:cache_options] || @locals[:cache_options] || {}
        keys_to_collection_map = {}

        @collection.each do |item|
          key = @options[:cache].respond_to?(:call) ? @options[:cache].call(item) : item

          key_with_digest = @view.cache_fragment_name(key)
          expanded_key = fragment_cache_key(key_with_digest)

          keys_to_collection_map[expanded_key] = item
        end

        # cache.read_multi & cache.write interfaces may require mutable keys, ie. dalli 2.6.0
        mutable_keys = keys_to_collection_map.keys.collect { |key| key.dup }

        result_hash = instrument_fragment_cache :read_fragment, mutable_keys do
          cache_store.read_multi(*mutable_keys)
        end

        # if we had a cached value, we don't need to render that object from the collection.
        # if it wasn't cached, we need to render those objects as before
        @collection = (keys_to_collection_map.keys - result_hash.keys).map do |key|
          keys_to_collection_map[key]
        end

        non_cached_results = []

        # sequentially render any non-cached objects remaining
        if @collection.any?
          non_cached_results = @template ? collection_with_template : collection_without_template
        end

        # sort the result according to the keys that were fed in, cache the non-cached results
        mutable_keys.each do |key|

          cached_value = result_hash[key]
          if cached_value
            results << cached_value
          else
            non_cached_result = non_cached_results.shift

            instrument_fragment_cache :write_fragment, key do
              cache_store.write(key, non_cached_result, additional_cache_options)
            end

            results << non_cached_result
          end
        end

      else
        results = @template ? collection_with_template : collection_without_template
      end

      results.join(spacer).html_safe
    end

    def cache_collection?
      cache_option = @options[:cache].presence || @locals[:cache].presence
      ActionController::Base.perform_caching && cache_option
    end

  class Railtie < Rails::Railtie
    initializer "multi_fetch_fragments.initialize" do |app|
      ActionView::PartialRenderer.class_eval do
        include MultiFetchFragments
      end
    end
  end
end
