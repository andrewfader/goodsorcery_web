# The issue_tag_counts rows one event increments, bounded per issue so that
# high-cardinality tags (request ids, user ids, URLs) cannot grow the table
# and the issue page's distribution query without limit:
#
# - a key keeps at most IssueTagCount::VALUES_PER_KEY distinct values; later
#   new values count towards that key's single "Other values" row;
# - an issue keeps at most IssueTagCount::KEYS_PER_ISSUE keys; later new keys
#   are not counted.
#
# Values already stored cost one indexed lookup; the bounded counts are only
# read when the event brings a value the issue has not seen. The bounds
# count distinct rows, never counts, so increments still pending in the
# counter buffer (which only ever adds to rows that exist) can't affect them.
class Ingest::TagRows
  def initialize(issue_id, tags)
    @issue_id, @tags = issue_id, tags
  end

  # Upsert rows sorted by (key, value_digest), so concurrent transactions lock
  # rows in the same order.
  def to_a
    @rows ||= @tags.filter_map { |key, value| row_for(key, value) }.sort_by { |row| row.values_at(:key, :value_digest) }
  end

  # The rows the issue already has (an "Other values" row too, once it
  # exists). With the counter buffer, these are counted there
  # (docs/ARCHITECTURE.md §2.5.2).
  def stored_rows = to_a.select { |row| stored_pairs.include?(row.values_at(:key, :value_digest)) }

  # The rows still to insert, values the issue hasn't seen yet, with the
  # value (encrypted on insert), which never goes to the buffer.
  def new_rows = to_a - stored_rows

  private
    def digests
      @digests ||= @tags.to_h { |key, value| [ key, IssueTagCount.value_digest(key, value) ] }
    end

    def row_for(key, value)
      return row(key, digests[key], value) if stored?(key)
      return unless key_room?(key)

      value_room?(key) ? row(key, digests[key], value) : row(key, IssueTagCount::OTHER_DIGEST, IssueTagCount::OTHER_VALUE)
    end

    def row(key, value_digest, value) = { issue_id: @issue_id, key:, value_digest:, value:, count: 1 }

    def stored?(key) = stored_pairs.include?([ key, digests[key] ])

    def stored_pairs
      @stored_pairs ||= IssueTagCount.where(issue_id: @issue_id, key: digests.keys,
                                            value_digest: [ *digests.values, IssueTagCount::OTHER_DIGEST ])
        .pluck(:key, :value_digest).to_set
    end

    def unseen_keys = @unseen_keys ||= digests.keys.reject { |key| stored?(key) }

    # Distinct values stored per unseen key (absent when the key is new).
    def value_counts
      @value_counts ||= IssueTagCount.where(issue_id: @issue_id, key: unseen_keys).group(:key).count
    end

    def value_room?(key) = value_counts.fetch(key, 0) < IssueTagCount::VALUES_PER_KEY

    def key_room?(key) = value_counts.key?(key) || admitted_new_keys.include?(key)

    def admitted_new_keys
      @admitted_new_keys ||= begin
        new_keys = unseen_keys - value_counts.keys
        room = new_keys.empty? ? 0 : IssueTagCount::KEYS_PER_ISSUE - IssueTagCount.where(issue_id: @issue_id).distinct.count(:key)
        new_keys.first(room.clamp(0..))
      end
    end
end
