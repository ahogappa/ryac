# frozen_string_literal: true

module Ryac
  module UnionFind
    def uf_init
      @parent = {}
      @rank = {}
    end

    def uf_root(key)
      @parent[key] = uf_root(@parent[key]) if @parent[key] != key
      @parent[key]
    end

    def merge_groups(key1, key2)
      root1 = uf_root(key1)
      root2 = uf_root(key2)
      return if root1 == root2

      if @rank[root1] < @rank[root2]
        @parent[root1] = root2
      elsif @rank[root1] > @rank[root2]
        @parent[root2] = root1
      else
        @parent[root2] = root1
        @rank[root1] += 1
      end
    end

    private

    def uf_add(key)
      @parent[key] ||= key
      @rank[key] ||= 0
    end

    def uf_remove(key)
      @parent.delete(key)
      @rank.delete(key)
    end
  end
end
