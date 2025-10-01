/*
/// Module: sui_gacha
module sui_gacha::sui_gacha;
*/

// For Move coding conventions, see
// https://docs.sui.io/concepts/sui-move-concepts/conventions

module sui_gacha::sui_gacha;
use sui::event;
use sui::random::{Self as rand, Random};
use sui::table;
use sui::coin;
use sui::sui::SUI;

const EInvalidArgs: u64 = 1;
const ETokenListMismatch: u64 = 2;
const ENotActive: u64 = 3;
const ESoldOut: u64 = 4;
const EIndexOutOfRange: u64 = 5;
const ECapMismatch: u64 = 6;
const EInvalidFee: u64 = 7;

/// Admin capability bound to a specific `Gacha` by its object ID.
public struct AdminCap has key, store {
    id: sui::object::UID,
    gacha_id: object::ID,
}

/// Shared gacha object. Anyone can draw when `active == true`.
public struct Gacha has key, store {
    id: sui::object::UID,
    active: bool,
    remaining: u64,
    total: u64,
    /// cumulative[i] = sum_{0..i}(amounts)
    cumulative: vector<u64>,
    /// LIFO stacks of concrete item ids per tier
    tier_item_ids: vector<vector<u64>>,
    /// Fisher–Yates sparse mapping: virtual index -> swapped value
    bucket: table::Table<u64, u64>,
    /// Fee receiver address
    treasury: address,
    /// Flat SUI fee per draw (in MIST)
    fee_amount: u64,
}

/// Prize object transferred to the recipient on draw
public struct Prize has key, store {
    id: sui::object::UID,
    tier: u64,
    item_id: u64,
}

/// Event emitted on draw
public struct DrawEvent has copy, drop, store {
    tier: u64,
    item_id: u64,
    to: address,
}

/// Create a new gacha, share it, and transfer an AdminCap to the sender.
entry fun create_gacha(
    amounts: vector<u64>,
    item_ids_per_tier: vector<vector<u64>>,
    treasury: address,
    fee_amount: u64,
    ctx: &mut sui::tx_context::TxContext,
) {
    let tier_count = vector::length(&amounts);
    assert!(tier_count > 0 && tier_count == vector::length(&item_ids_per_tier), EInvalidArgs);

    let (total, cumulative, tiers) = build_inventory(amounts, item_ids_per_tier);
    assert!(total > 0, EInvalidArgs);

    let g = Gacha {
        id: object::new(ctx),
        active: false,
        remaining: total,
        total,
        cumulative,
        tier_item_ids: tiers,
        bucket: table::new<u64, u64>(ctx),
        treasury,
        fee_amount,
    };

    let g_id = object::id(&g);
    transfer::share_object(g);

    transfer::public_transfer(
        AdminCap { id: object::new(ctx), gacha_id: g_id },
        tx_context::sender(ctx),
    );
}

fun build_inventory(
    amounts: vector<u64>,
    item_ids_per_tier: vector<vector<u64>>,
): (u64, vector<u64>, vector<vector<u64>>) {
    let tier_count = vector::length(&amounts);
    let mut total: u64 = 0;
    let mut cumulative = vector::empty<u64>();
    let mut tiers: vector<vector<u64>> = vector::empty<vector<u64>>();
    let mut i: u64 = 0;
    while (i < tier_count) {
        let amt = *vector::borrow(&amounts, i);
        let ids_ref = vector::borrow(&item_ids_per_tier, i);
        assert!(vector::length(ids_ref) == amt, ETokenListMismatch);
        total = total + amt;
        vector::push_back(&mut cumulative, total);
        let mut stack: vector<u64> = vector::empty<u64>();
        let mut j: u64 = 0;
        let n_ids = vector::length(ids_ref);
        while (j < n_ids) {
            let v = *vector::borrow(ids_ref, j);
            vector::push_back(&mut stack, v);
            j = j + 1;
        };
        vector::push_back(&mut tiers, stack);
        i = i + 1;
    };
    (total, cumulative, tiers)
}

/// Activate or deactivate the gacha. Only the matching AdminCap holder can call.
entry fun set_active(cap: &AdminCap, gacha: &mut Gacha, active: bool) {
    assert!(object::id(gacha) == cap.gacha_id, ECapMismatch);
    gacha.active = active;
}

/// Secure single-transaction draw using Sui on-chain randomness.
/// `draw` is an `entry` and requires `&Random` per Sui rules to prevent composition.
entry fun draw(
    gacha: &mut Gacha,
    to: address,
    fee: coin::Coin<SUI>,
    r: &Random,
    ctx: &mut sui::tx_context::TxContext,
) {
    assert!(gacha.active, ENotActive);
    let rem = gacha.remaining;
    assert!(rem > 0, ESoldOut);

    // Charge fee before randomness
    assert!(coin::value(&fee) == gacha.fee_amount, EInvalidFee);
    transfer::public_transfer(fee, gacha.treasury);

    let mut generator = rand::new_generator(r, ctx);
    let idx = rand::generate_u64_in_range(&mut generator, 0, rem - 1);

    let ticket_one_based = pick(gacha, idx);
    let tier = tier_for(&gacha.cumulative, ticket_one_based);
    let item_id = pop_item_from_tier(&mut gacha.tier_item_ids, tier);

    event::emit(DrawEvent { tier, item_id, to });
    transfer::public_transfer(Prize { id: object::new(ctx), tier, item_id }, to);
}

/// Internal: Fisher–Yates style no-replacement pick
fun pick(gacha: &mut Gacha, i: u64): u64 {
    let rem = gacha.remaining;
    assert!(i < rem, EIndexOutOfRange);

    let picked = if (table::contains(&gacha.bucket, i)) {
        *table::borrow(&gacha.bucket, i)
    } else { i };

    let last_idx = rem - 1;
    let last_val = if (table::contains(&gacha.bucket, last_idx)) {
        *table::borrow(&gacha.bucket, last_idx)
    } else { last_idx };

    if (table::contains(&gacha.bucket, i)) {
        *table::borrow_mut(&mut gacha.bucket, i) = last_val;
    } else {
        table::add(&mut gacha.bucket, i, last_val);
    };
    if (table::contains(&gacha.bucket, last_idx)) {
        let _dropped: u64 = table::remove(&mut gacha.bucket, last_idx);
    };

    gacha.remaining = rem - 1;
    picked + 1
}

/// Internal: Convert 1-based ticket into a tier index using cumulative tier amounts.
fun tier_for(cumulative: &vector<u64>, ticket_one_based: u64): u64 {
    let n = vector::length(cumulative);
    let mut i: u64 = 0;
    while (i < n) {
        if (ticket_one_based <= *vector::borrow(cumulative, i)) return i;
        i = i + 1;
    };
    abort EIndexOutOfRange
}

/// Internal: pop item id (LIFO) from given tier index
fun pop_item_from_tier(tiers: &mut vector<vector<u64>>, tier: u64): u64 {
    let list_ref = vector::borrow_mut(tiers, tier);
    let len = vector::length(list_ref);
    assert!(len > 0, EIndexOutOfRange);
    vector::pop_back(list_ref)
}

// ------------------------
// Getters (views)
// ------------------------
public fun is_active(g: &Gacha): bool { g.active }

public fun remaining(g: &Gacha): u64 { g.remaining }

public fun total(g: &Gacha): u64 { g.total }

public fun tier_count(g: &Gacha): u64 { vector::length(&g.cumulative) }

public fun tier_remaining_items(g: &Gacha, tier: u64): u64 {
    let list_ref = vector::borrow(&g.tier_item_ids, tier);
    vector::length(list_ref)
}

#[test_only]
public(package) fun new_gacha_for_test(
    amounts: vector<u64>,
    item_ids_per_tier: vector<vector<u64>>,
    active: bool,
    ctx: &mut sui::tx_context::TxContext,
): Gacha {
    let (total, cumulative, tiers) = build_inventory(amounts, item_ids_per_tier);
    Gacha {
        id: object::new(ctx),
        active,
        remaining: total,
        total,
        cumulative,
        tier_item_ids: tiers,
        bucket: table::new<u64, u64>(ctx),
        treasury: @0x0,
        fee_amount: 0,
    }
}

#[test_only]
public(package) fun destroy_for_test(g: Gacha) {
    let Gacha { id, active: _, remaining: _, total: _, cumulative: _, tier_item_ids: _, bucket, treasury: _, fee_amount: _ } =
        g;
    table::destroy_empty(bucket);
    object::delete(id)
}

#[test_only]
public(package) fun draw_with_fixed_index(
    gacha: &mut Gacha,
    to: address,
    idx: u64,
    ctx: &mut sui::tx_context::TxContext,
) {
    assert!(gacha.active, ENotActive);
    let rem = gacha.remaining;
    assert!(rem > 0, ESoldOut);
    let ticket_one_based = pick(gacha, idx);
    let tier = tier_for(&gacha.cumulative, ticket_one_based);
    let item_id = pop_item_from_tier(&mut gacha.tier_item_ids, tier);
    event::emit(DrawEvent { tier, item_id, to });
    transfer::public_transfer(Prize { id: object::new(ctx), tier, item_id }, to);
}

// ------------------------
// Test-only pure helpers (no TxContext required)
// ------------------------
#[test_only]
public(package) fun test_build_cumulative(amounts: vector<u64>): vector<u64> {
    let mut cumulative = vector::empty<u64>();
    let mut total: u64 = 0;
    let n = vector::length(&amounts);
    let mut i: u64 = 0;
    while (i < n) {
        total = total + *vector::borrow(&amounts, i);
        vector::push_back(&mut cumulative, total);
        i = i + 1;
    };
    cumulative
}

#[test_only]
public(package) fun test_tier_for_wrapper(cumulative: vector<u64>, ticket: u64): u64 {
    tier_for(&cumulative, ticket)
}

#[test_only]
public(package) fun test_pick_sequence_no_ctx(total: u64, indices: vector<u64>): vector<u64> {
    let mut remaining = total;
    let mut picked_tickets: vector<u64> = vector::empty<u64>();
    // sparse map simulated via vector initialized to identity
    let mut map: vector<u64> = vector::empty<u64>();
    let mut k: u64 = 0;
    while (k < total) { vector::push_back(&mut map, k); k = k + 1; };
    let mut t: u64 = 0;
    let m = vector::length(&indices);
    while (t < m) {
        let idx = *vector::borrow(&indices, t);
        assert!(idx < remaining, EIndexOutOfRange);
        let cur = *vector::borrow(&map, idx);
        let last_idx = remaining - 1;
        let last_val = *vector::borrow(&map, last_idx);
        *vector::borrow_mut(&mut map, idx) = last_val;
        *vector::borrow_mut(&mut map, last_idx) = cur; // not necessary but keeps invariant
        remaining = remaining - 1;
        vector::push_back(&mut picked_tickets, cur + 1);
        t = t + 1;
    };
    picked_tickets
}

#[test_only]
public(package) fun test_validate_inventory(amounts: vector<u64>, item_ids_per_tier: vector<vector<u64>>): u64 {
    let (total, _cumulative, _tiers) = build_inventory(amounts, item_ids_per_tier);
    total
}

#[test_only]
public(package) fun test_simulate_gacha(
    amounts: vector<u64>,
    mut_item_ids_per_tier: vector<vector<u64>>,
    indices: vector<u64>,
): (vector<u64>, vector<u64>, vector<u64>, u64) {
    // Returns: (picked_tiers, picked_item_ids, per_tier_remaining, remaining)
    let (total, cumulative, mut mut_tiers) = build_inventory(amounts, mut_item_ids_per_tier);
    let tickets = test_pick_sequence_no_ctx(total, indices);
    let mut picked_tiers: vector<u64> = vector::empty<u64>();
    let mut picked_item_ids: vector<u64> = vector::empty<u64>();
    let mut i: u64 = 0;
    let n = vector::length(&tickets);
    while (i < n) {
        let ticket = *vector::borrow(&tickets, i);
        let tier = tier_for(&cumulative, ticket);
        vector::push_back(&mut picked_tiers, tier);
        // pop item id from selected tier (LIFO)
        let list_ref = vector::borrow_mut(&mut mut_tiers, tier);
        let len = vector::length(list_ref);
        assert!(len > 0, EIndexOutOfRange);
        let item_id = vector::pop_back(list_ref);
        vector::push_back(&mut picked_item_ids, item_id);
        i = i + 1;
    };
    // build per-tier remaining counts and remaining total
    let mut per_tier_remaining: vector<u64> = vector::empty<u64>();
    let mut total_remaining: u64 = 0;
    let tc = vector::length(&mut_tiers);
    let mut t: u64 = 0;
    while (t < tc) {
        let c = vector::length(vector::borrow(&mut_tiers, t));
        vector::push_back(&mut per_tier_remaining, c);
        total_remaining = total_remaining + c;
        t = t + 1;
    };
    (picked_tiers, picked_item_ids, per_tier_remaining, total_remaining)
}
