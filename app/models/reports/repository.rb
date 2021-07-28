require_relative "experiment"
module Reports
  class Repository
    include BustCache
    include Memery
    include Scientist

    def self.use_schema_v2?
      @use_schema_v2 ||= false
    end

    class << self
      attr_writer :use_schema_v2
    end

    def initialize(regions, periods:, reporting_schema_v2: self.class.use_schema_v2?)
      @regions = Array(regions).map(&:region)
      @periods = if periods.is_a?(Period)
        Range.new(periods, periods)
      else
        periods
      end
      @period_type = @periods.first.type
      @reporting_schema_v2 = reporting_schema_v2
      raise ArgumentError, "Quarter periods not supported" if @period_type != :month
      @schema = if reporting_schema_v2?
        SchemaV2.new(@regions, periods: @periods)
      else
        SchemaV1.new(@regions, periods: @periods)
      end

      @bp_measures_query = BPMeasuresQuery.new
      @follow_ups_query = FollowUpsQuery.new
      @no_bp_measure_query = NoBPMeasureQuery.new
      @registered_patients_query = RegisteredPatientsQuery.new
    end

    attr_reader :bp_measures_query
    attr_reader :follow_ups_query
    attr_reader :no_bp_measure_query
    attr_reader :period_type
    attr_reader :periods
    attr_reader :regions
    attr_reader :registered_patients_query
    attr_reader :schema

    def reporting_schema_v2?
      @reporting_schema_v2
    end

    delegate :cache, :logger, to: Rails

    DELEGATED_METHODS = [
      :adjusted_patients_with_ltfu,
      :adjusted_patients_without_ltfu,
      :assigned_patients,
      :complete_monthly_registrations,
      :controlled_rates,
      :controlled,
      :cumulative_assigned_patients,
      :cumulative_registrations,
      :earliest_patient_recorded_at,
      :earliest_patient_recorded_at_period,
      :ltfu_rates,
      :ltfu,
      :monthly_registrations,
      :uncontrolled_rates,
      :uncontrolled
    ]

    delegate(*DELEGATED_METHODS, to: :schema)

    alias_method :adjusted_patients, :adjusted_patients_without_ltfu

    # Returns registration counts per region / period counted by registration_user
    memoize def monthly_registrations_by_user
      items = regions.map { |region| RegionEntry.new(region, __method__, group_by: :registration_user_id, period_type: period_type) }
      result = cache.fetch_multi(*items, force: bust_cache?) do |entry|
        registered_patients_query.count(entry.region, period_type, group_by: :registration_user_id)
      end
      result.each_with_object({}) { |(region_entry, counts), hsh|
        hsh[region_entry.region.slug] = counts
      }
    end

    memoize def missed_visits_without_ltfu
      region_period_cached_query(__method__) do |entry|
        slug, period = entry.slug, entry.period
        patients = denominator(entry.region, entry.period)
        patients_with_visits = controlled[slug][period] + uncontrolled[slug][period] + visited_without_bp_taken[slug][period]
        patients - patients_with_visits
      end
    end

    # To determine the missed visits percentage, we sum the remaining percentages and subtract that from 100.
    # If we determined the percentage directly, we would have cases where the percentages do not add up to 100
    # due to rounding and losing precision.
    memoize def missed_visits_without_ltfu_rates
      region_period_cached_query(__method__) do |entry|
        slug, period = entry.slug, entry.period
        visit_rates = controlled_rates[slug][period] + uncontrolled_rates[slug][period] + visited_without_bp_taken_rate[slug][period]
        100 - visit_rates
      end
    end

    memoize def missed_visits_with_ltfu
      region_period_cached_query(__method__, with_ltfu: true) do |entry|
        slug = entry.slug
        patients = denominator(entry.region, entry.period, with_ltfu: true)
        patients_with_visits = controlled[slug][entry.period] + uncontrolled[slug][entry.period] + visited_without_bp_taken[slug][entry.period]
        patients - patients_with_visits
      end
    end

    # To determine the missed visits percentage, we sum the remaining percentages and subtract that from 100.
    # If we determined the percentage directly, we would have cases where the percentages do not add up to 100
    # due to rounding and losing precision.
    memoize def missed_visits_with_ltfu_rates
      region_period_cached_query(__method__, with_ltfu: true) do |entry|
        slug, period = entry.slug, entry.period
        visit_rates = controlled_rates(with_ltfu: true)[slug][period] +
          uncontrolled_rates(with_ltfu: true)[slug][period] +
          visited_without_bp_taken_rate(with_ltfu: true)[slug][period]
        100 - visit_rates
      end
    end

    alias_method :missed_visits, :missed_visits_without_ltfu
    alias_method :missed_visits_rate, :missed_visits_without_ltfu_rates

    # Returns Follow ups per Region / Period. Takes an optional group_by clause (commonly used to group by `blood_pressures.user_id`)
    memoize def hypertension_follow_ups(group_by: nil)
      items = regions.map { |region| RegionEntry.new(region, __method__, group_by: group_by, period_type: period_type) }
      result = cache.fetch_multi(*items, force: bust_cache?) do |entry|
        follow_ups_query.hypertension(entry.region, period_type, group_by: group_by)
      end
      result.each_with_object({}) { |(region_entry, counts), hsh|
        hsh[region_entry.region.slug] = counts
      }
    end

    memoize def bp_measures_by_user
      items = regions.map { |region| RegionEntry.new(region, __method__, group_by: :user_id, period_type: period_type) }
      result = cache.fetch_multi(*items, force: bust_cache?) do |entry|
        bp_measures_query.count(entry.region, period_type, group_by: :user_id)
      end
      result.each_with_object({}) { |(region_entry, counts), hsh|
        hsh[region_entry.region.slug] = counts
      }
    end

    memoize def visited_without_bp_taken
      region_period_cached_query(__method__) do |entry|
        no_bp_measure_query.call(entry.region, entry.period)
      end
    end

    memoize def visited_without_bp_taken_rate(with_ltfu: false)
      region_period_cached_query(__method__, with_tlfu: with_ltfu) do |entry|
        numerator = visited_without_bp_taken[entry.slug][entry.period]
        total = denominator(entry.region, entry.period, with_ltfu: with_ltfu)
        percentage(numerator, total)
      end
    end

    private

    # Return the actual 'active range' for a Region - this will be the from the first recorded at in a region until
    # the end of the period range requested.
    def active_range(region)
      start = [earliest_patient_recorded_at_period[region.slug], periods.begin].compact.max
      (start..periods.end)
    end

    def denominator(region, period, with_ltfu: false)
      if with_ltfu
        cumulative_assigned_patients[region.slug][period.adjusted_period]
      else
        cumulative_assigned_patients[region.slug][period.adjusted_period] - ltfu[region.slug][period]
      end
    end

    # Generate all necessary cache keys for a calculation, then yield to the block for every entry.
    # Once all results are returned via fetch_multi, return the data in a standard format of:
    #   {
    #     region_1_slug: { period_1: value, period_2: value }
    #     region_2_slug: { period_1: value, period_2: value }
    #   }
    #
    def region_period_cached_query(calculation, **options, &block)
      results = regions.each_with_object({}) { |region, hsh| hsh[region.slug] = Hash.new(0) }
      items = cache_entries(calculation, **options)
      cached_results = cache.fetch_multi(*items, force: bust_cache?) { |entry| block.call(entry) }
      cached_results.each { |(entry, count)| results[entry.region.slug][entry.period] = count }
      results
    end

    # Generate all necessary region period cache entries, only going back to the earliest
    # patient registration date for Periods. This ensures that we don't create many cache entries
    # with 0 data for newer Regions.
    def cache_entries(calculation, **options)
      combinations = regions.each_with_object([]) do |region, results|
        earliest_period = earliest_patient_recorded_at_period[region.slug]
        next if earliest_period.nil?
        periods_with_data = periods.select { |period| period >= earliest_period }
        results.concat(periods_with_data.to_a.map { |period| [region, period] })
      end
      combinations.map { |region, period| Reports::RegionPeriodEntry.new(region, period, calculation, options) }
    end

    def percentage(numerator, denominator)
      return 0 if denominator == 0 || numerator == 0
      ((numerator.to_f / denominator) * 100).round(PERCENTAGE_PRECISION)
    end
  end
end
