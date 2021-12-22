/**
 * Module     : ICMonitor.mo
 * Author     : ICLight.house Team
 * License    : GNU General Public License v3.0
 * Stability  : Experimental
 * Canister   : 73hjh-6qaaa-aaaak-aacaq-cai
 * Website    : https://ICMonitor.io
 * Github     : https://github.com/iclighthouse/ICMonitor/
 */
import Prim "mo:⛔";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Option "mo:base/Option";
import Array "mo:base/Array";
import Int "mo:base/Int";
import Nat "mo:base/Nat";
import Nat32 "mo:base/Nat32";
import Nat64 "mo:base/Nat64";
import Float "mo:base/Float";
import Time "mo:base/Time";
import Trie "mo:base/Trie";
import Binary "./lib/Binary";
import Cycles "mo:base/ExperimentalCycles";
import CyclesWallet "./sys/CyclesWallet";
import Deque "mo:base/Deque";
import Ledger "./sys/Ledger2";
import List "mo:base/List";
import Iter "mo:base/Iter";
import Hash "mo:base/Hash";
import Blackhole "./sys/Blackhole";
import Hex "./lib/Hex";
import Tools "./lib/Tools";
import Error "mo:base/Error";
import CF "./lib/CF";
import DRC207 "./lib/DRC207";

shared(installMsg) actor class ICMonitor() = this {
    /// types
    type AccountId = Blob;
    type Heartbeat = Int; // Number of heartbeats
    type Subscriber = Principal;
    type CanisterId = Principal;
    type CanisterStatus = DRC207.canister_status;
    type EnAutoRenewal = Bool; // The canister SHOULD implement wallet_receive()
    type RenewalValue = Nat; // e8s
    type EventType = {
        #StatusChanged;
        #MemorySizeGreaterThan: Nat;
        #MemorySizeReachingAllocation;
        #CyclesLessThan: Nat;
        #ControllersChanged;
        #ModuleHashChanged;
        #TimerTick; 
    };
    type Subscription = {
        canister: CanisterId;
        subEventTypes: [EventType];
        enAutoRenewal: EnAutoRenewal;
        renewalValue: RenewalValue;
    };
    type MonitorStats = {
        heartbeatCount: Nat;
        canisterCount: Nat;
        subscriberCount: Nat;
        updateTime: Time.Time;
    };
    type Event = { 
        canister: CanisterId; 
        subscriber: Subscriber;
        time: Time.Time; 
        eventType: EventType; 
        canisterStatus: CanisterStatus; 
    };
    type Config = { 
        BLACKHOLE: ?Text;
        INTERVAL: ?Int;
        ICP_FEE: ?Nat64;
        DEAL_SIZE: ?Nat;
        CFACCOUNTID: ?Text;
        EVENT_HEARTBEATS: ?Int;
    };
    type StatsResponse = {
        totalHeartbeat: Int;
        monitorStats: MonitorStats;
        eventCount: Nat;
    };
    type SubscriptionResponse = [{
        subscriber: Subscriber;
        subscription: Subscription; 
        canisterStatus: CanisterStatus; 
        heartbeat: Heartbeat;
        timerHeartbeat: Heartbeat;
    }];
    type EventKey = {
        canisterId: CanisterId; 
        subscriber: Subscriber; 
        eventType: EventType;
    };

    /// stable variables
    private stable var INTERVAL: Int = 60 * 1000000000; // Monitor heartbeat interval
    private stable var EVENT_HEARTBEATS: Int = 3*24*12; // The same event is sent only once within a period of x heartbeats.
    private stable var ICP_FEE: Nat64 = 10000; // e8s 
    private stable var DEAL_SIZE: Nat = 30; // Monitors 10 containers each time
    private stable var BLACKHOLE: Text = "7hdtw-jqaaa-aaaak-aaccq-cai";
    private stable var CFACCOUNTID: Hex.Hex = "f4be3d790b8d9bd16bf4b2407268d87d58c5a7a3b9e9264a2cfbd33d030cc98b"; // = cyclesFinance.getAccountId("73hjh-6qaaa-aaaak-aacaq-cai");
    private stable var owner: Principal = installMsg.caller;
    private stable var launchTime: Time.Time = Time.now(); 
    private stable var monitorStats: MonitorStats = { heartbeatCount = 0; canisterCount = 0; subscriberCount = 0; updateTime = Time.now(); };
    private stable var canisters: Trie.Trie<CanisterId, (CanisterStatus, Heartbeat, DRC207.DRC207Support)> = Trie.empty();
    private stable var subscriptions: Trie.Trie2D<CanisterId, Subscriber, ([EventType], EnAutoRenewal, RenewalValue, Heartbeat)> = Trie.empty();
    private stable var events = Deque.empty<Event>();
    private stable var eventFilter: Trie.Trie<EventKey, Heartbeat> = Trie.empty();
    private stable var heartbeatIndex: Heartbeat = 0;
    private stable var eventCount: Nat = 0; //
    private stable var transferIndex: Nat64 = 0;
    private stable var cfAccountId: AccountId = Option.get(Tools.accountHexToAccountBlob(CFACCOUNTID), Blob.fromArray([]));
    private let ledger: Ledger.Self = actor("ryjl3-tyaaa-aaaaa-aaaba-cai");
    private let cyclesFinance: CF.Self = actor("6nmrm-laaaa-aaaak-aacfq-cai");
    /**
     * Local functions
     */
    private func keyp(t: Principal) : Trie.Key<Principal> { return { key = t; hash = Principal.hash(t) }; };
    private func keyi(t: Int) : Trie.Key<Int> { return { key = t; hash = Int.hash(t) }; };
    private func keye(t: EventKey) : Trie.Key<EventKey> { 
        var eventNo: Nat32 = 0;
        switch(t.eventType){
            case(#StatusChanged){ eventNo:=1 };
            case(#MemorySizeGreaterThan(v)){ eventNo:=2 };
            case(#MemorySizeReachingAllocation){ eventNo:=3 };
            case(#CyclesLessThan(v)){ eventNo:=4 };
            case(#ControllersChanged){ eventNo:=5 };
            case(#ModuleHashChanged){ eventNo:=6 };
            case(#TimerTick){ eventNo:=7 };
        };
        return { key = t; hash = Principal.hash(t.canisterId) & Principal.hash(t.subscriber) | eventNo;  }; 
    };
    private func eventKeyEqual(a: EventKey, b: EventKey) : Bool {
        return a.canisterId == b.canisterId and a.subscriber == b.subscriber and a.eventType == b.eventType;
    };
    private func _onlyOwner(_caller: Principal) : Bool { 
        return _caller == owner;
    };  // assert(_onlyOwner(msg.caller));
    private func _onlyCanisterController(_caller: Principal, _canisterId: CanisterId) : Bool { 
        switch(Trie.get(canisters, keyp(_canisterId), Principal.equal)){
            case(?(status, hb, drc207)){ 
                switch(Array.find(status.settings.controllers, func (p:Principal):Bool{ Principal.equal(_caller,p) })){
                    case(?(controller)){ return true; };
                    case(_){ return false; };
                }; 
            };
            case(_){ return false; };
        };
    };
    private func _onlyCanisterSubscriber(_caller: Principal, _canisterId: CanisterId) : Bool { 
        switch(Trie.get(subscriptions, keyp(_canisterId), Principal.equal)){
            case(?(trie)){ 
                switch(Trie.get(trie, keyp(_caller), Principal.equal)){
                    case(?(item)){ return true; };
                    case(_){ return false; };
                };
            };
            case(_){ return false; };
        };
    };
    /// ICP Account & transfer
    private func _getSA(_sa: Blob) : Blob{
        var sa = Blob.toArray(_sa);
        while (sa.size() < 32){
            sa := Array.append([0:Nat8], sa);
        };
        return Blob.fromArray(sa);
    };
    private func _getAccount(_p: Principal) : AccountId{
        return Blob.fromArray(Tools.principalToAccount(_p, null));
    };
    private func _getDepositAccount(_p: Principal) : AccountId{
        let main = Principal.fromActor(this);
        let sa = Blob.toArray(Principal.toBlob(_p));
        return Blob.fromArray(Tools.principalToAccount(main, ?sa));
    };
    private func _getIcpBalance(_a: AccountId) : async Nat{ //e8s
        let res = await ledger.account_balance({
            account = _a;
        });
        return Nat64.toNat(res.e8s);
    };
    private func _sendIcpFromSA(_from: Principal, _to: AccountId, _value: Nat) : async Ledger.TransferResult{
        var amount = Nat64.fromNat(_value);
        amount := if (amount > ICP_FEE){ amount - ICP_FEE } else { 0 };
        let res = await ledger.transfer({
            to = _to;
            fee = { e8s = ICP_FEE; };
            memo = transferIndex;
            from_subaccount = ?_getSA(Principal.toBlob(_from));
            created_at_time = null;
            amount = { e8s = amount };
        });
        transferIndex += 1;
        return res;
    };
    private func _icpToCycles(_from: Principal, _to: CanisterId, _e8s: Nat) : async CF.TxnResult{
        if (_e8s <= Nat64.toNat(ICP_FEE)) { throw Error.reject("Invalid value!"); };
        let res = await _sendIcpFromSA(_from, cfAccountId, _e8s);
        switch(res){
            case(#Err(e)){ throw Error.reject("ICP sending error! Check ICP balance!");};
            case(#Ok(blockHeight)){
                let res = await cyclesFinance.icpToCycles(Nat.sub(_e8s, Nat64.toNat(ICP_FEE)), _to, ?Binary.BigEndian.fromNat64(blockHeight));
                return res;
            };
        };
    };
    private func _heartbeatCount() : (){
        let heartbeat0 = monitorStats.updateTime / INTERVAL;
        let heartbeat1 = Time.now() / INTERVAL;
        if (heartbeat1 > heartbeat0){
            monitorStats := { 
                heartbeatCount = monitorStats.heartbeatCount+1; 
                canisterCount = monitorStats.canisterCount; 
                subscriberCount = monitorStats.subscriberCount;
                updateTime = Time.now()};
        };
    };
    private func _eventFilter(_event: Event) : Bool{
        var flag: Bool = true;
        for ((key, hb) in Trie.iter(eventFilter)){
            if (key.canisterId == _event.canister and key.subscriber == _event.subscriber and 
            key.eventType == _event.eventType and heartbeatIndex < hb+EVENT_HEARTBEATS) { flag := false; };
            if (heartbeatIndex >= hb+EVENT_HEARTBEATS){
                eventFilter := Trie.remove(eventFilter, keye(key), eventKeyEqual).0;
            };
        };
        if (flag){
            eventFilter := Trie.put(eventFilter, keye({
                canisterId = _event.canister; 
                subscriber = _event.subscriber;
                eventType = _event.eventType;
            }), eventKeyEqual, heartbeatIndex).0;
            return true;
        }else{
            return false;
        };
    };
    private func _pushEvent(_event: Event): (){ // Save up to 3000 records
        events := Deque.pushFront(events, _event);
        var size = List.size(events.0) + List.size(events.1);
        while (size > 3000){
            size -= 1;
            switch (Deque.popBack(events)){
                case(?(q, v)){
                    events := q;
                };
                case(_){};
            };
        };
    };
    private func _getEvents(_canisterId: ?CanisterId, _subscriber: ?Principal): [Event]{
        let l = List.append(events.0, List.reverse(events.1));
        let a = List.toArray(l);
        switch(_canisterId){
            case(?(canisterId)){
                switch(_subscriber){
                    case(?(subscriber)){
                        return Array.filter(a, func (item: Event): Bool{ canisterId == item.canister and subscriber == item.subscriber });
                    };
                    case(_){
                        return Array.filter(a, func (item: Event): Bool{ canisterId == item.canister });
                    };
                };
            };
            case(_){ 
                switch(_subscriber){
                    case(?(subscriber)){
                        return Array.filter(a, func (item: Event): Bool{ subscriber == item.subscriber });
                    };
                    case(_){
                        return a;
                    };
                };
             };
        };
    };
    private func _getCanisterStatus(_canisterId: CanisterId, _init: Bool) : async ?(CanisterStatus, Heartbeat, DRC207.DRC207Support){
        let canisterActor: DRC207.Self = actor(Principal.toText(_canisterId));
        var timerSetting : { enable: Bool; interval_seconds: ?Nat; } = { enable = false; interval_seconds = null; }; 
        var drc207Setting: DRC207.DRC207Support = {
            monitorable_by_self = false;
            monitorable_by_blackhole = { allowed = false; canister_id = null; };
            cycles_receivable = false;
            timer = timerSetting; 
        };
        var temp: [CanisterStatus] = [];
        if (_init){
            try {
                drc207Setting := await canisterActor.drc207();
            }catch(e){
                try{
                    await canisterActor.timer_tick(); 
                    timerSetting := { enable = true; interval_seconds = ?0; }; 
                }catch(e){};
                try{
                    let blackholeActor: Blackhole.Self = actor(BLACKHOLE);
                    ignore await blackholeActor.canister_status({canister_id = _canisterId; }); 
                    drc207Setting := {
                        monitorable_by_self = false;
                        monitorable_by_blackhole = { allowed = true; canister_id = ?Principal.fromText(BLACKHOLE); };
                        cycles_receivable = false;
                        timer = timerSetting; 
                    };
                }catch(e){
                    try{
                        ignore await canisterActor.canister_status(); 
                        drc207Setting := {
                            monitorable_by_self = true;
                            monitorable_by_blackhole = { allowed = false; canister_id = null; };
                            cycles_receivable = false;
                            timer = timerSetting; 
                        };
                    }catch(e){
                        return null;
                    };
                };
            };
        } else {
            switch(Trie.get(canisters, keyp(_canisterId), Principal.equal)){
                case(?(status, hbi, setting)){
                    temp := [status];
                    drc207Setting := setting;
                };
                case(_){ return null; };
            };
        };
        try {
            if (drc207Setting.monitorable_by_self){
                temp := [await canisterActor.canister_status()];
            }else if (drc207Setting.monitorable_by_blackhole.allowed){
                switch(drc207Setting.monitorable_by_blackhole.canister_id){
                    case(?(blackholeCanisterId)){ 
                        let blackholeActor: Blackhole.Self = actor(Principal.toText(blackholeCanisterId));
                        temp := [await blackholeActor.canister_status({canister_id = _canisterId; })]; 
                    };
                    case(_){ return null; };
                };
            }else{
                return null;
            };
        }catch(e){
            return null;
        };
        canisters := Trie.put(canisters, keyp(_canisterId), Principal.equal, (temp[0], heartbeatIndex, drc207Setting)).0;
        return ?(temp[0], heartbeatIndex, drc207Setting);
    };

    /* 
     * Shared Functions
     */
    /// stats
    public query func stats() : async (StatsResponse){
        let beat0 = launchTime / INTERVAL;
        let beat1 = Time.now() / INTERVAL;
        return {totalHeartbeat = beat1 - beat0; monitorStats = monitorStats; eventCount = eventCount};
    };
    /// canister subscribes events
    public shared(msg) func subscribe(_sub: Subscription) : async Bool{
        let optCanister = Trie.get(canisters, keyp(_sub.canister), Principal.equal);
        var canisterCount = monitorStats.canisterCount;
        var hasSubscribed: Bool = false;
        var subscriberCount = monitorStats.subscriberCount;
        switch(await _getCanisterStatus(_sub.canister, true)){
            case(?(status, hbi, setting)){};
            case(_){ return false;};
        };
        if (Option.isNull(optCanister)) { canisterCount += 1; };
        switch(Trie.get(subscriptions, keyp(_sub.canister), Principal.equal)){
            case(?(trie)){
                for ((subscriber, subInfo) in Trie.iter(trie)){
                    if (subscriber == msg.caller) { hasSubscribed := true; };
                };
            };
            case(_){};
        };
        if (not(hasSubscribed)) { subscriberCount += 1; };
        // access
        assert(not(hasSubscribed) or 
            _onlyCanisterSubscriber(msg.caller, _sub.canister) or 
            _onlyCanisterController(msg.caller, _sub.canister));
        subscriptions := Trie.put2D(subscriptions, keyp(_sub.canister), Principal.equal, keyp(msg.caller), Principal.equal, 
        (_sub.subEventTypes, _sub.enAutoRenewal, _sub.renewalValue, 0) );
        monitorStats := {heartbeatCount = monitorStats.heartbeatCount; canisterCount = canisterCount; subscriberCount = subscriberCount; updateTime = monitorStats.updateTime; };
        return true;
    };
    /// unsubscribe
    public shared(msg) func unsubscribe(_canisterId: CanisterId, _subscriber: Subscriber) : async (){
        assert(_onlyCanisterSubscriber(msg.caller, _canisterId) or 
            _onlyCanisterController(msg.caller, _canisterId) or 
            _onlyOwner(msg.caller));
        canisters := Trie.remove(canisters, keyp(_canisterId), Principal.equal).0;
        subscriptions := Trie.remove2D(subscriptions, keyp(_canisterId), Principal.equal, keyp(_subscriber), Principal.equal).0;
        monitorStats := {heartbeatCount = monitorStats.heartbeatCount; canisterCount = monitorStats.canisterCount; subscriberCount = Nat.max(monitorStats.subscriberCount,1) - 1; updateTime = monitorStats.updateTime; };
    };
    /// query subscription info
    public query(msg) func subscription(_canisterId: CanisterId, _subscriber: ?Subscriber) : async SubscriptionResponse{
        assert(_onlyCanisterSubscriber(msg.caller, _canisterId) or 
            _onlyCanisterController(msg.caller, _canisterId) or 
            _onlyOwner(msg.caller));
        var ret: SubscriptionResponse = [];
        switch(_subscriber){
            case(null){
                switch(Trie.get(subscriptions, keyp(_canisterId), Principal.equal)){
                    case(?(trie)){
                        for ((subscriber, subInfo) in Trie.iter(trie)){
                            var sub: Subscription = { canister = _canisterId; subEventTypes = subInfo.0; enAutoRenewal = subInfo.1; renewalValue = subInfo.2; };
                            switch(Trie.get(canisters, keyp(_canisterId), Principal.equal)){
                                case(?(status, hb, drc207)){ 
                                    ret := Array.append(ret, [{subscriber=subscriber; subscription=sub; canisterStatus=status; heartbeat=hb; timerHeartbeat=subInfo.3}]); 
                                };
                                case(_){};
                            };
                        };
                    };
                    case(_){};
                };
            };
            case(?(subscriber)){
                switch(Trie.get(subscriptions, keyp(_canisterId), Principal.equal)){
                    case(?(trie)){
                        switch(Trie.get(trie, keyp(subscriber), Principal.equal)){
                            case(?(subInfo)){
                                var sub: Subscription = { canister = _canisterId; subEventTypes = subInfo.0; enAutoRenewal = subInfo.1; renewalValue = subInfo.2; };
                                switch(Trie.get(canisters, keyp(_canisterId), Principal.equal)){
                                    case(?(status, hb, drc207)){ 
                                        ret := Array.append(ret, [{subscriber=subscriber; subscription=sub; canisterStatus=status; heartbeat=hb; timerHeartbeat=subInfo.3}]); 
                                    };
                                    case(_){};
                                };
                            };
                            case(_){};
                        };
                    };
                    case(_){};
                };
            };
        };
        return ret;
    };
    /// heartbeat: monitor
    public shared func heartbeat() : async ({events: [Event]; completely: Bool}){
        _heartbeatCount();
        heartbeatIndex := Time.now()/INTERVAL;
        let trieCanisters = Trie.filter(canisters, func (canister: CanisterId, status: (CanisterStatus, Heartbeat, DRC207.DRC207Support)): Bool{ heartbeatIndex > status.1 });
        var _events: [Event] = [];
        var completely: Bool = false;
        var i: Nat = 0;
        label monitor for ((canisterId, status_) in Trie.iter(trieCanisters)){
            if (i < DEAL_SIZE){
                var status = status_;
                switch(await _getCanisterStatus(canisterId, false)){
                    case(?(getStatus)){
                        status := getStatus;
                    };
                    case(_){ continue monitor; };
                };
                switch(Trie.get(subscriptions, keyp(canisterId), Principal.equal)){ 
                    // subscriber -> ([EventType], EnAutoRenewal, RenewalValue)
                    case(?(trie)){
                        for ((subscriber, subInfo) in Trie.iter(trie)){
                            for (eventType in subInfo.0.vals()){
                                var trigger = false;
                                var flag = false;
                                switch(eventType){
                                    case(#StatusChanged){
                                        if (status_.0.status != status.0.status){ trigger := true; flag := true; };
                                    };
                                    case(#MemorySizeGreaterThan(v)){
                                        if (status.0.memory_size > v){ trigger := true; };
                                    };
                                    case(#MemorySizeReachingAllocation){
                                        if (status.0.settings.memory_allocation > 0 and status.0.memory_size >= status.0.settings.memory_allocation*95/100 and 
                                        status.0.memory_size < status.0.settings.memory_allocation*98/100)
                                        { trigger := true; };
                                    };
                                    case(#CyclesLessThan(v)){
                                        if (status.0.cycles < v and status.0.cycles > status.0.settings.freezing_threshold){ 
                                            trigger := true; 
                                            if (subInfo.1){
                                                let res = /*await*/ _icpToCycles(subscriber, canisterId, subInfo.2);
                                            };
                                        };
                                    };
                                    case(#ControllersChanged){ //not(Array.equal())
                                        if (status_.0.settings.controllers != status.0.settings.controllers){ trigger := true; flag := true; };
                                    };
                                    case(#ModuleHashChanged){
                                        if (status_.0.module_hash != status.0.module_hash){ trigger := true; flag := true; };
                                    };
                                    case(#TimerTick){
                                        if (status.2.timer.enable){
                                            let timerInerval = Option.get(status.2.timer.interval_seconds, 0) * 1000000000;
                                            var intervalHB = timerInerval / INTERVAL;
                                            if (intervalHB == 0) { intervalHB := 1; };
                                            if (heartbeatIndex >= subInfo.3 + intervalHB){ 
                                                let canisterActor: DRC207.Self = actor(Principal.toText(canisterId));
                                                let res = /*await*/ canisterActor.timer_tick();
                                                subscriptions := Trie.put2D(subscriptions, keyp(canisterId), Principal.equal, keyp(subscriber), Principal.equal, 
                                                (subInfo.0, subInfo.1, subInfo.2, heartbeatIndex) );
                                            };
                                        };
                                    };
                                };
                                if (trigger){
                                    let event: Event = {
                                        canister = canisterId; 
                                        subscriber = subscriber; 
                                        time = Time.now(); 
                                        eventType = eventType; 
                                        canisterStatus = status.0;
                                    };
                                    if (flag or _eventFilter(event)){
                                        _events := Array.append(_events, [event]);
                                        _pushEvent(event);
                                        eventCount += 1;
                                    };
                                };
                            };
                        };
                    };
                    case(_){};
                };
            };
            i += 1;
        };
        if (i >= Trie.size(trieCanisters)) { completely := true; };
        return {events = _events; completely = completely };
    };
    /// get events
    public query func getEvents(_canisterId: ?CanisterId, _subscriber: ?Principal, _size: ?Nat, _page: ?Nat) : async ({events: [Event]; total: Nat; size: Nat; page: Nat }){
        let size = Option.get(_size, 50);
        let page = Option.get(_page, 1); // from 1
        let es = _getEvents(_canisterId, _subscriber);
        let total = es.size();
        return {events = Tools.slice(es, Nat.sub(page, 1)*size, ?Nat.sub(page*size, 1)); total = total; size = size; page = page; };
    };
    /// get ICP deposit accountId
    public query func getAccountId(_account: Principal) : async Text{
        return Hex.encode(Blob.toArray(_getDepositAccount(_account)));
    };
    /// query icp balance in this canister
    public shared(msg) func icpBalance() : async (e8s: Nat){  
        return await _getIcpBalance(_getDepositAccount(msg.caller));
    };
    /// withdraw icp from this canister
    public shared(msg) func icpWithdraw(_e8s: Nat) : async Ledger.TransferResult{  
        return await _sendIcpFromSA(msg.caller, _getAccount(msg.caller), _e8s);
    };

    /* 
     * Monitor
     */
    /// DRC207 support
    public func drc207() : async DRC207.DRC207Support{
        return {
            monitorable_by_self = true;
            monitorable_by_blackhole = { allowed = true; canister_id = ?Principal.fromText("7hdtw-jqaaa-aaaak-aaccq-cai"); };
            cycles_receivable = true;
            timer = { enable = true; interval_seconds = ?300; }; 
        };
    };
    /// canister_status
    public func canister_status() : async DRC207.canister_status {
        let ic : DRC207.IC = actor("aaaaa-aa");
        await ic.canister_status({ canister_id = Principal.fromActor(this) });
    };
    /// timer_tick() is executed once per n(specified) heartbeats by Monitor (there is no guarantee that each heartbeat will be executed successfully)
    public func timer_tick() : async (){
        test_timer_count += 1;
    };
    private var test_timer_count: Nat32 = 0;
    public func test_timer_value() : async Nat32{ test_timer_count; };
    /// receive cycles
    public func wallet_receive(): async (){
        let amout = Cycles.available();
        let accepted = Cycles.accept(amout);
    };

    /* 
     * Owner's Management
     */
    public query func getConfig() : async Config{ 
        return {
            BLACKHOLE = ?BLACKHOLE;
            INTERVAL = ?INTERVAL;
            ICP_FEE = ?ICP_FEE;
            DEAL_SIZE = ?DEAL_SIZE;
            CFACCOUNTID = ?CFACCOUNTID;
            EVENT_HEARTBEATS = ?EVENT_HEARTBEATS;
        };
    };
    public shared(msg) func config(config: Config) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        BLACKHOLE := Option.get(config.BLACKHOLE, BLACKHOLE);
        INTERVAL := Option.get(config.INTERVAL, INTERVAL);
        ICP_FEE := Option.get(config.ICP_FEE, ICP_FEE);
        DEAL_SIZE := Option.get(config.DEAL_SIZE, DEAL_SIZE);
        CFACCOUNTID := Option.get(config.CFACCOUNTID, CFACCOUNTID);
        cfAccountId := Option.get(Tools.accountHexToAccountBlob(CFACCOUNTID), Blob.fromArray([]));
        EVENT_HEARTBEATS := Option.get(config.EVENT_HEARTBEATS, EVENT_HEARTBEATS);
        return true;
    };
    public query func getOwner() : async Principal{  
        return owner;
    };
    public shared(msg) func changeOwner(_newOwner: Principal) : async Bool{  
        assert(_onlyOwner(msg.caller));
        owner := _newOwner;
        return true;
    };
    /// canister memory
    public query func getMemory() : async (Nat,Nat,Nat,Nat32){
        return (Prim.rts_memory_size(), Prim.rts_heap_size(), Prim.rts_total_allocation(), Prim.stableMemorySize());
    };
    /// canister cycles
    public query func getCycles() : async Nat{
        return return Cycles.balance();
    };
};