#[test_only]
module sui_gacha::sui_gacha_tests;

use sui_gacha::sui_gacha;

const EUnexpected: u64 = 9999;

#[test]
fun test_cumulative_and_tier() {
    let amounts = vector[2, 1, 3];
    let cumulative = sui_gacha::test_build_cumulative(amounts);
    assert!(vector::length(&cumulative) == 3, EUnexpected);
    assert!(*vector::borrow(&cumulative, 0) == 2, EUnexpected);
    assert!(*vector::borrow(&cumulative, 1) == 3, EUnexpected);
    assert!(*vector::borrow(&cumulative, 2) == 6, EUnexpected);
    assert!(sui_gacha::test_tier_for_wrapper(cumulative, 1) == 0, EUnexpected);
}

#[test]
fun test_inventory_validation() {
    let total = sui_gacha::test_validate_inventory(
        vector[2, 3],
        vector[
            vector[101, 102],
            vector[201, 202, 203]
        ]
    );
    assert!(total == 5, EUnexpected);
}

#[test]
fun test_pick_sequence_no_ctx() {
    // total 5, indices [0, 0, 0, 0, 0] should pick tickets [1,?, ?, ?, ?] without replacement
    let picked = sui_gacha::test_pick_sequence_no_ctx(5, vector[0, 0, 0, 0, 0]);
    assert!(vector::length(&picked) == 5, EUnexpected);
    // tickets are 1-based; first must be 1 by construction
    assert!(*vector::borrow(&picked, 0) == 1, EUnexpected);
}

#[test]
fun test_simulate_end_to_end_no_replacement() {
    // amounts [2, 1] with concrete ids
    let (picked_tiers, picked_ids, per_tier_remaining, total_remaining) = sui_gacha::test_simulate_gacha(
        vector[2, 1],
        vector[
            vector[11, 12],
            vector[21]
        ],
        // draw 3 times with deterministic indices 0 each time
        vector[0, 0, 0]
    );
    assert!(vector::length(&picked_tiers) == 3, EUnexpected);
    assert!(vector::length(&picked_ids) == 3, EUnexpected);
    assert!(total_remaining == 0, EUnexpected);
    assert!(vector::length(&per_tier_remaining) == 2, EUnexpected);
    assert!(*vector::borrow(&per_tier_remaining, 0) == 0, EUnexpected);
    assert!(*vector::borrow(&per_tier_remaining, 1) == 0, EUnexpected);
}

#[test]
fun test_per_tier_depletion_and_order() {
    // amounts [1, 2], item ids LIFO per tier
    let (_picked_tiers, picked_ids, _per_tier_remaining, total_remaining) = sui_gacha::test_simulate_gacha(
        vector[1, 2],
        vector[
            vector[101],
            vector[201, 202]
        ],
        // 3 draws
        vector[0, 0, 0]
    );
    // total consumed
    assert!(total_remaining == 0, EUnexpected);
    assert!(vector::length(&picked_ids) == 3, EUnexpected);
}

#[test]
fun test_full_exhaustion_last_index_sequence() {
    // total=5, indices hit the last slot each time, should not abort and end at 0 remaining
    let (_tiers, _ids, _per_tier_remaining, total_remaining) = sui_gacha::test_simulate_gacha(
        vector[2, 3],
        vector[
            vector[1, 2],
            vector[3, 4, 5]
        ],
        vector[4, 3, 2, 1, 0]
    );
    assert!(total_remaining == 0, EUnexpected);
}

#[test]
fun test_many_tiers_one_each_16() {
    let (_tiers, _ids, per_tier_remaining, total_remaining) = sui_gacha::test_simulate_gacha(
        // 16 tiers, 1 each
        vector[1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        vector[
            vector[1],vector[2],vector[3],vector[4],vector[5],vector[6],vector[7],vector[8],
            vector[9],vector[10],vector[11],vector[12],vector[13],vector[14],vector[15],vector[16]
        ],
        // draw 16 times from index 0
        vector[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
    );
    assert!(total_remaining == 0, EUnexpected);
    assert!(vector::length(&per_tier_remaining) == 16, EUnexpected);
}

#[test]
fun test_single_tier_16_items() {
    let (_tiers, _ids, per_tier_remaining, total_remaining) = sui_gacha::test_simulate_gacha(
        vector[16],
        vector[
            vector[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16]
        ],
        // always take index 0
        vector[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
    );
    assert!(total_remaining == 0, EUnexpected);
    assert!(vector::length(&per_tier_remaining) == 1, EUnexpected);
    assert!(*vector::borrow(&per_tier_remaining, 0) == 0, EUnexpected);
}

#[test, expected_failure(abort_code = 2, location = sui_gacha)]
fun test_mismatch_amounts_and_ids_fails() {
    // amounts[1] but 0 ids -> ETokenListMismatch = 2
    let _ = sui_gacha::test_validate_inventory(vector[1], vector[vector[]]);
}

#[test, expected_failure(abort_code = 5, location = sui_gacha)]
fun test_invalid_index_abort() {
    // total=2, indices [0, 2] -> second step 2 >= remaining(1) aborts with EIndexOutOfRange = 5
    let _ = sui_gacha::test_pick_sequence_no_ctx(2, vector[0, 2]);
}
