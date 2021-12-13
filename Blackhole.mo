/**
 * Module     : Blackhole.mo
 * Author     : ninegua
 * Stability  : Stable
 * Canister   : 73hjh-6qaaa-aaaak-aacaq-cai
 * Github     : https://github.com/iclighthouse/ICMonitor
 * Refer      : https://github.com/ninegua/ic-blackhole
 */
actor {
  public type canister_id = Principal;

  public type definite_canister_settings = {
    freezing_threshold : Nat;
    controllers : [Principal];
    memory_allocation : Nat;
    compute_allocation : Nat;
  };

  public type canister_status = {
     status : { #stopped; #stopping; #running };
     memory_size : Nat;
     cycles : Nat;
     settings : definite_canister_settings;
     module_hash : ?[Nat8];
  };

  public type IC = actor {
   canister_status : { canister_id : canister_id } -> async canister_status;
  };

  let ic : IC = actor("aaaaa-aa");

  /// query info about the canister which is set "7hdtw-jqaaa-aaaak-aaccq-cai" to its controllers 
  public func canister_status(request : { canister_id : canister_id }) : async canister_status {
    await ic.canister_status(request)
  };
}