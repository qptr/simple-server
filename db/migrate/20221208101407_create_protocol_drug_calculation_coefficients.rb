class CreateProtocolDrugCalculationCoefficients < ActiveRecord::Migration[6.1]
  def change
    create_table :protocol_drug_calculation_coefficients do |t|
      t.uuid :protocol_id
      t.json :coefficients

      t.timestamps
    end
  end
end
