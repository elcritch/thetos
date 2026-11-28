## Compare Sigils' subscription sequence with TrieMultiMap using real callbacks.
## From the Thetos root, build with the adjacent Sigils checkout and its Atlas dependencies.
##   nim c -d:release --mm:arc -d:features.sigils.thetos -d:features.sigils.sigNameAsString --path:../sigils --path:../sigils/deps/results --path:../sigils/deps/stack_strings --path:../sigils/deps/threading benchmarks/bsigilslots.nim
## Pass a trial number to rotate sizes and the order of the two stores.
import std/[monotimes, os, strutils, times]
import sigils/agents
import thetos/triemultimap

const lookupQuarter {.intdefine.} = 62_500

type
  Slots = TrieMultiMap[SigilName, Subscription]
  MapAgent = ref object of Agent
    slots: Slots
    hasWildcard: bool

  Receiver = ref object of Agent
    calls, id: int

proc receive(agent: Agent, params: SigilParams) =
  inc Receiver(agent).calls

proc add(owner: Agent, sig: SigilName, sub: Subscription) =
  doAssert owner.subcriptions.addSubscriptionSorted(sig, sub)

proc add(owner: MapAgent, sig: SigilName, sub: Subscription) =
  if sig == AnySigilName:
    owner.hasWildcard = true
  owner.slots.add(sig, sub)

iterator matching(owner: Agent, sig: SigilName): lent Subscription =
  for sub in owner.getSubscriptions(sig):
    yield sub

iterator matching(owner: MapAgent, sig: SigilName): lent Subscription =
  if not owner.hasWildcard or sig == AnySigilName:
    for sub in owner.slots.values(sig):
      yield sub
  else:
    let wildcardFirst = compareSigilName(AnySigilName, sig) < 0
    let first = if wildcardFirst: AnySigilName else: sig
    let second = if wildcardFirst: sig else: AnySigilName
    # Pin both runs if a callback changes the map between groups.
    let snapshot = owner.slots
    for sub in snapshot.values(first):
      yield sub
    for sub in snapshot.values(second):
      yield sub

proc prepared(target: Receiver): Subscription =
  Subscription(tgt: target.unsafeWeakRef().asAgent(), packedSlot: receive).prepareSubscription()

proc verifyMatches() =
  let flat = Agent()
  let packed = MapAgent()
  var targets: seq[Receiver]
  defer:
    flat.subcriptions.setLen(0)
  let names = [toSigilName("!early"), AnySigilName, toSigilName("late")]
  for name in [names[1], names[0], names[2]]:
    for i in 0 ..< (if name == AnySigilName: 2 else: 70):
      let target = Receiver(id: targets.len)
      targets.add(target)
      let sub = prepared(target)
      flat.add(name, sub)
      packed.add(name, sub)
    # Check the small leaf as well as runs spanning multiple tree leaves.
    for key in [names[0], names[1], names[2], toSigilName("absent")]:
      var expected, actual: seq[int]
      for sub in flat.matching(key):
        expected.add(Receiver(sub.tgt[]).id)
      for sub in packed.matching(key):
        actual.add(Receiver(sub.tgt[]).id)
      doAssert expected == actual

proc run[T: Agent](label: static string, signals, fanout: int) =
  let ownerCount = min(20_000, 250_000 div (signals * fanout))
  var receivers = newSeq[Receiver](fanout)
  var subs = newSeq[Subscription](fanout)
  for i in 0 ..< fanout:
    receivers[i] = Receiver()
    subs[i] = prepared(receivers[i])
  var names = newSeq[SigilName](signals)
  for i in 0 ..< signals:
    names[i] = toSigilName("valueChanged" & $i)
  let missing = toSigilName("unconnected")
  var owners = newSeq[T](ownerCount)
  defer:
    for owner in owners:
      owner.subcriptions.setLen(0)
  for owner in owners.mitems:
    owner = T()
  # Exclude the owner objects, their inline handles, and the above fixtures.
  let before = getOccupiedMem()
  for owner in owners:
    for name in names:
      for sub in subs:
        owner.add(name, sub)
  let retained = getOccupiedMem() - before
  let lookups = 4 * (lookupQuarter div max(1, fanout div 4))
  var ownerIndex, keyIndex: int
  let start = getMonoTime()
  for i in 0 ..< lookups:
    let sig =
      if (i and 3) == 0:
        missing
      else:
        names[keyIndex]
    for sub in owners[ownerIndex].matching(sig):
      sub.packedSlot(sub.tgt[], default(SigilParams))
    inc ownerIndex
    if ownerIndex == ownerCount:
      ownerIndex = 0
    if (i and 3) != 0:
      inc keyIndex
      if keyIndex == signals:
        keyIndex = 0
  let elapsed = (getMonoTime() - start).inNanoseconds
  for receiver in receivers:
    doAssert receiver.calls == lookups * 3 div 4
  echo label,
    ",",
    signals,
    ",",
    fanout,
    ",",
    elapsed.float / lookups.float,
    ",",
    retained.float / ownerCount.float

proc compare(signals, fanout, order: int) =
  for i in 0 ..< 2:
    if (order + i) mod 2 == 0:
      run[Agent]("seq", signals, fanout)
    else:
      run[MapAgent]("TrieMultiMap", signals, fanout)

when isMainModule:
  verifyMatches()
  let trial =
    if paramCount() == 0:
      1
    else:
      parseInt(paramStr(1))
  echo "# nameBytes=",
    sizeof(SigilName),
    " subscription=",
    sizeof(Subscription),
    " flatHandle=",
    sizeof(seq[SubscriptionEntry]),
    " mapHandle=",
    sizeof(Slots)
  echo "store,signals,slotsPerSignal,nsPerLookup,heapBytesPerSender"
  for step in 0 ..< 32:
    let n = ((trial - 1) * 7 + step * 11) mod 32 + 1
    compare(1, n, trial + step)
    if n > 1:
      compare(n, 1, trial + step + 1)
  for (signals, fanout) in [
    (4, 2), (4, 4), (8, 2), (8, 3), (16, 3), (64, 4), (1, 64), (16, 64)
  ]:
    compare(signals, fanout, trial + signals + fanout)
