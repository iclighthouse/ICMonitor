// e3mmv-5qaaa-aaaah-aadma-cai

module {
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

  public type Self = actor {
    canister_status: shared (request : { canister_id : canister_id }) -> async canister_status;
  };
}