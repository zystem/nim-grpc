## Well-known types: generated code against protoc, and the nimgrpc/wkt helpers.

import std/[unittest, os, osproc, options, tables, times, json]
import nimgrpc/wkt
import ./gen/[wkt_use_pb, codec_pb]

const dir = currentSourcePath.parentDir / "proto"

proc load(name: string): seq[byte] =
  let s = readFile(dir / name)
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(result[0].addr, s[0].unsafeAddr, s.len)

proc protocDecode(data: seq[byte]): string =
  let p = getEnv("PROTOC", findExe("protoc"))
  if p.len == 0: return ""
  let tmp = getTempDir() / "twkt.bin"
  var s = newString(data.len)
  if data.len > 0: copyMem(s[0].addr, data[0].unsafeAddr, data.len)
  writeFile(tmp, s)
  let (outp, code) = execCmdEx(p & " --decode=codec.wkt.Event -I" & dir.quoteShell &
                               " wkt_use.proto < " & tmp.quoteShell)
  doAssert code == 0, outp
  outp

suite "well-known types in generated code":
  let original = load("wkt.bin")
  let e = Event.decode(original)

  test "Timestamp and Duration":
    check e.at.seconds == 1761955200 and e.at.nanos == 123456789
    check e.took.seconds == -3 and e.took.nanos == -500000000

  test "Any holding a message from another file":
    check e.detail.typeUrl == "type.googleapis.com/codec.test.Scalars"
    check isA[Scalars](e.detail)
    let s = unpack[Scalars](e.detail)
    check s.fInt32 == -42 and s.fString == "inside any"
    expect ProtobufError:
      discard unpack[Event](e.detail)

  test "Struct, wrappers, FieldMask, Empty, Value":
    check e.attrs.fields.len == 6
    check e.attrs.fields["name"].stringValue == some("x")
    check e.attrs.fields["list"].listValue.values.len == 2
    check e.hasMaybeCount and e.maybeCount.value == 0   # a set wrapper holding 0
    check not e.hasMaybeName
    check e.mask.paths == @["a.b", "c"]
    check e.hasNothing
    check e.values.len == 1 and e.values[0].stringValue == some("v")

  test "protoc decodes our encoding to the same message":
    let a = protocDecode(original)
    if a.len == 0: skip()
    else: check protocDecode(e.encode) == a

  test "services may use well-known types":
    check compiles(newEventsClient(GrpcChannel()).ping(Empty()))

suite "nimgrpc/wkt helpers":
  test "Timestamp <-> Time":
    let t = initTime(1761955200, 123456789)
    check t.toTimestamp == Timestamp(seconds: 1761955200, nanos: 123456789)
    check t.toTimestamp.toTime == t
    check initTime(-1, 999_999_999).toTimestamp == Timestamp(seconds: -1, nanos: 999_999_999)
    expect ValueError: discard Timestamp(seconds: 0, nanos: -1).toTime
    expect ValueError: discard Timestamp(seconds: 253402300800).toTime

  test "Duration <-> times.Duration":
    let d = initDuration(seconds = -3, milliseconds = -500)
    check d.toProtoDuration == duration_pb.Duration(seconds: -3, nanos: -500000000)
    check d.toProtoDuration.toDuration == d
    expect ValueError: discard duration_pb.Duration(seconds: 1, nanos: -1).toDuration

  test "Any pack and unpack":
    let a = pack(Scalars(fBool: true, fString: "s"))
    check a.typeUrl == "type.googleapis.com/codec.test.Scalars"
    check unpack[Scalars](a).fString == "s"
    check Scalars.protoName == "codec.test.Scalars"
    check Everything_Inner.protoName == "codec.test.Everything.Inner"

  test "Struct <-> JSON":
    let j = %*{"a": 1, "b": [true, nil, "x"], "c": {"d": 2.5}}
    let s = j.toStruct
    check s.fields["a"].numberValue == some(1.0)
    check s.toJson == %*{"a": 1.0, "b": [true, nil, "x"], "c": {"d": 2.5}}
    check Struct.decode(s.encode).toJson == s.toJson
    check Event.decode(load("wkt.bin")).attrs.toJson["obj"] == %*{"k": false}
    expect ValueError: discard (%*[1, 2]).toStruct
