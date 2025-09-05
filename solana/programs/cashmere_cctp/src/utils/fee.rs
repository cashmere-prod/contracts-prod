const BP: u64 = 10000;

pub fn calculate_fee(amount: u64, fee_bp: u64, fee_static: u64) -> u64 {
    (fee_bp * amount) / BP + fee_static
}
