module Reports
  # Handles the task of returning summed values from Reports::FacilityState for an array of
  # regions. Must be called with regions all having the same region_type.
  class RegionSummary
    def self.call(regions, range: nil)
      new(regions, range: range).call
    end

    FIELDS = %i[
      adjusted_controlled_under_care
      adjusted_missed_visit_lost_to_follow_up
      adjusted_missed_visit_under_care
      adjusted_patients_under_care
      adjusted_uncontrolled_under_care
      adjusted_visited_no_bp_lost_to_follow_up
      adjusted_visited_no_bp_under_care
      cumulative_assigned_patients
      cumulative_registrations
      cumulative_diabetes_registrations
      cumulative_hypertension_and_diabetes_registrations
      lost_to_follow_up
      diabetes_lost_to_follow_up
      under_care
      diabetes_under_care
      monthly_registrations
      monthly_diabetes_registrations
      monthly_hypertension_and_diabetes_registrations
      monthly_overdue_calls
      monthly_follow_ups
      monthly_diabetes_follow_ups
      total_appts_scheduled
      appts_scheduled_0_to_14_days
      appts_scheduled_15_to_31_days
      appts_scheduled_32_to_62_days
      appts_scheduled_more_than_62_days
      cumulative_assigned_diabetic_patients
      adjusted_diabetes_patients_under_care
      adjusted_bs_below_200_under_care
      adjusted_random_bs_below_200_under_care
      adjusted_post_prandial_bs_below_200_under_care
      adjusted_fasting_bs_below_200_under_care
      adjusted_hba1c_bs_below_200_under_care
      adjusted_visited_no_bs_under_care
      adjusted_bs_missed_visit_under_care
      adjusted_bs_missed_visit_lost_to_follow_up
      adjusted_bs_200_to_300_under_care
      adjusted_random_bs_200_to_300_under_care
      adjusted_post_prandial_bs_200_to_300_under_care
      adjusted_fasting_bs_200_to_300_under_care
      adjusted_hba1c_bs_200_to_300_under_care
      adjusted_bs_over_300_under_care
      adjusted_random_bs_over_300_under_care
      adjusted_post_prandial_bs_over_300_under_care
      adjusted_fasting_bs_over_300_under_care
      adjusted_hba1c_bs_over_300_under_care
      diabetes_total_appts_scheduled
      diabetes_appts_scheduled_0_to_14_days
      diabetes_appts_scheduled_15_to_31_days
      diabetes_appts_scheduled_32_to_62_days
      diabetes_appts_scheduled_more_than_62_days
      dead
      diabetes_dead
    ].sort.freeze

    UNDER_CARE_WITH_LTFU = %i[
      adjusted_missed_visit
      adjusted_visited_no_bp
      adjusted_bs_missed_visit
    ].freeze

    attr_reader :id_field
    attr_reader :range
    attr_reader :region_type
    attr_reader :regions
    attr_reader :slug_field

    def self.under_care_with_ltfu(field)
      Arel.sql(<<-SQL)
        COALESCE(SUM(#{field}_under_care::int + #{field}_lost_to_follow_up::int), 0) as #{field}_under_care_with_lost_to_follow_up
      SQL
    end

    SUMS = FIELDS.map { |field| Arel.sql("COALESCE(SUM(#{field}::int), 0) as #{field}") }
    CALCULATIONS = UNDER_CARE_WITH_LTFU.map { |field| under_care_with_ltfu(field) }

    def initialize(regions, range: nil)
      @range = range
      @regions = Array(regions).map(&:region)
      if @regions.map(&:region_type).uniq.size != 1
        raise ArgumentError, "RegionSummary must be called with regions of the same region_type"
      end
      @region_type = @regions.first.region_type
      @id_field = "#{region_type}_region_id"
      @slug_field = region_type == "facility" ? "#{region_type}_region_slug" : "#{region_type}_slug"
      @results = @regions.each_with_object({}) { |region, hsh| hsh[region.slug] = {} }
    end

    def call
      query = for_regions
      query = query.where(month_date: range) if range
      facility_states = query.group(:month_date, slug_field).select("month_date", slug_field, SUMS, CALCULATIONS).order(:month_date)
      facility_states.each { |facility_state|
        @results[facility_state.send(slug_field)][facility_state.period] = facility_state.attributes
      }
      @results
    end

    def for_regions
      query = FacilityState
        .where(id_field => regions.map(&:id))

      filter = "cumulative_registrations IS NOT NULL OR cumulative_assigned_patients IS NOT NULL OR monthly_follow_ups IS NOT NULL"
      if regions.any?(&:diabetes_management_enabled?)
        filter += " OR cumulative_diabetes_registrations IS NOT NULL OR cumulative_assigned_diabetic_patients IS NOT NULL OR monthly_diabetes_follow_ups IS NOT NULL"
      end

      query.where(filter)
    end
  end
end
