class UpdateMaterializedPatientSummariesToVersion2 < ActiveRecord::Migration[5.2]
  def change
    update_view :materialized_patient_summaries, version: 2, revert_to_version: 1, materialized: true
  end
end
