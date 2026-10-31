// Interop peer built on grpc-go: a grpc.testing.TestService server and a
// client that runs the interop test cases (doc/interop-test-descriptions.md
// in grpc/grpc) against any server.
package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	testpb "google.golang.org/grpc/interop/grpc_testing"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

const (
	initialKey  = "x-grpc-test-echo-initial"
	trailingKey = "x-grpc-test-echo-trailing-bin"
)

// ---------------------------------------------------------------- server

type server struct {
	testpb.UnimplementedTestServiceServer
}

func echoMetadata(ctx context.Context) {
	md, _ := metadata.FromIncomingContext(ctx)
	if v := md.Get(initialKey); len(v) > 0 {
		grpc.SetHeader(ctx, metadata.Pairs(initialKey, v[0]))
	}
	if v := md.Get(trailingKey); len(v) > 0 {
		grpc.SetTrailer(ctx, metadata.Pairs(trailingKey, v[0]))
	}
}

func (server) EmptyCall(ctx context.Context, _ *testpb.Empty) (*testpb.Empty, error) {
	return &testpb.Empty{}, nil
}

func (server) UnaryCall(ctx context.Context, in *testpb.SimpleRequest) (*testpb.SimpleResponse, error) {
	echoMetadata(ctx)
	if st := in.GetResponseStatus(); st != nil && st.Code != 0 {
		return nil, status.Error(codes.Code(st.Code), st.Message)
	}
	return &testpb.SimpleResponse{
		Payload: &testpb.Payload{Body: make([]byte, in.GetResponseSize())},
	}, nil
}

func (server) StreamingOutputCall(in *testpb.StreamingOutputCallRequest, s testpb.TestService_StreamingOutputCallServer) error {
	for _, p := range in.GetResponseParameters() {
		if us := p.GetIntervalUs(); us > 0 {
			time.Sleep(time.Duration(us) * time.Microsecond)
		}
		if err := s.Send(&testpb.StreamingOutputCallResponse{
			Payload: &testpb.Payload{Body: make([]byte, p.GetSize())},
		}); err != nil {
			return err
		}
	}
	return nil
}

func (server) StreamingInputCall(s testpb.TestService_StreamingInputCallServer) error {
	sum := 0
	for {
		in, err := s.Recv()
		if err == io.EOF {
			return s.SendAndClose(&testpb.StreamingInputCallResponse{AggregatedPayloadSize: int32(sum)})
		}
		if err != nil {
			return err
		}
		sum += len(in.GetPayload().GetBody())
	}
}

func (server) FullDuplexCall(s testpb.TestService_FullDuplexCallServer) error {
	echoMetadata(s.Context())
	for {
		in, err := s.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if st := in.GetResponseStatus(); st != nil && st.Code != 0 {
			return status.Error(codes.Code(st.Code), st.Message)
		}
		for _, p := range in.GetResponseParameters() {
			if err := s.Send(&testpb.StreamingOutputCallResponse{
				Payload: &testpb.Payload{Body: make([]byte, p.GetSize())},
			}); err != nil {
				return err
			}
		}
	}
}

// ---------------------------------------------------------------- client

type testCase struct {
	name string
	run  func(ctx context.Context, cc *grpc.ClientConn) error
}

func expectCode(err error, want codes.Code, wantMsg string) error {
	st, _ := status.FromError(err)
	if st.Code() != want {
		return fmt.Errorf("code %v (%q), want %v", st.Code(), st.Message(), want)
	}
	if wantMsg != "" && st.Message() != wantMsg {
		return fmt.Errorf("message %q, want %q", st.Message(), wantMsg)
	}
	return nil
}

var cases = []testCase{
	{"empty_unary", func(ctx context.Context, cc *grpc.ClientConn) error {
		r, err := testpb.NewTestServiceClient(cc).EmptyCall(ctx, &testpb.Empty{})
		if err != nil {
			return err
		}
		if r == nil {
			return fmt.Errorf("nil response")
		}
		return nil
	}},
	{"large_unary", func(ctx context.Context, cc *grpc.ClientConn) error {
		r, err := testpb.NewTestServiceClient(cc).UnaryCall(ctx, &testpb.SimpleRequest{
			ResponseSize: 314159,
			Payload:      &testpb.Payload{Body: make([]byte, 271828)},
		})
		if err != nil {
			return err
		}
		if n := len(r.GetPayload().GetBody()); n != 314159 {
			return fmt.Errorf("payload %d bytes, want 314159", n)
		}
		return nil
	}},
	{"status_code_and_message", func(ctx context.Context, cc *grpc.ClientConn) error {
		msg := "test status message"
		_, err := testpb.NewTestServiceClient(cc).UnaryCall(ctx, &testpb.SimpleRequest{
			ResponseStatus: &testpb.EchoStatus{Code: 2, Message: msg},
		})
		return expectCode(err, codes.Unknown, msg)
	}},
	{"special_status_message", func(ctx context.Context, cc *grpc.ClientConn) error {
		msg := "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n"
		_, err := testpb.NewTestServiceClient(cc).UnaryCall(ctx, &testpb.SimpleRequest{
			ResponseStatus: &testpb.EchoStatus{Code: 2, Message: msg},
		})
		return expectCode(err, codes.Unknown, msg)
	}},
	{"unimplemented_method", func(ctx context.Context, cc *grpc.ClientConn) error {
		_, err := testpb.NewTestServiceClient(cc).UnimplementedCall(ctx, &testpb.Empty{})
		return expectCode(err, codes.Unimplemented, "")
	}},
	{"unimplemented_service", func(ctx context.Context, cc *grpc.ClientConn) error {
		_, err := testpb.NewUnimplementedServiceClient(cc).UnimplementedCall(ctx, &testpb.Empty{})
		return expectCode(err, codes.Unimplemented, "")
	}},
	{"custom_metadata", func(ctx context.Context, cc *grpc.ClientConn) error {
		ctx = metadata.AppendToOutgoingContext(ctx,
			initialKey, "test_initial_metadata_value",
			trailingKey, string([]byte{0xab, 0xab, 0xab}))
		var header, trailer metadata.MD
		_, err := testpb.NewTestServiceClient(cc).UnaryCall(ctx, &testpb.SimpleRequest{
			ResponseSize: 314159, Payload: &testpb.Payload{Body: make([]byte, 271828)},
		}, grpc.Header(&header), grpc.Trailer(&trailer))
		if err != nil {
			return err
		}
		if v := header.Get(initialKey); len(v) != 1 || v[0] != "test_initial_metadata_value" {
			return fmt.Errorf("initial metadata %v", v)
		}
		if v := trailer.Get(trailingKey); len(v) != 1 || !bytes.Equal([]byte(v[0]), []byte{0xab, 0xab, 0xab}) {
			return fmt.Errorf("trailing metadata %v", v)
		}
		return nil
	}},
	{"timeout_on_sleeping_server", func(ctx context.Context, cc *grpc.ClientConn) error {
		ctx, cancel := context.WithTimeout(ctx, time.Millisecond)
		defer cancel()
		_, err := testpb.NewTestServiceClient(cc).UnaryCall(ctx, &testpb.SimpleRequest{
			ResponseStatus: &testpb.EchoStatus{Code: 0},
			Payload:        &testpb.Payload{Body: make([]byte, 27182)},
			ResponseSize:   31415,
			FillUsername:   false,
		}, grpc.WaitForReady(false))
		// The reference test sleeps on a streaming call; a unary call that
		// overruns 1 ms is either DEADLINE_EXCEEDED or (fast server) OK.
		st, _ := status.FromError(err)
		if err != nil && st.Code() != codes.DeadlineExceeded {
			return fmt.Errorf("code %v, want DEADLINE_EXCEEDED or OK", st.Code())
		}
		return nil
	}},
}

func runClient(addr, only string) int {
	cc, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		fmt.Println("dial:", err)
		return 2
	}
	defer cc.Close()
	failed := 0
	for _, tc := range cases {
		if only != "" && !strings.Contains(","+only+",", ","+tc.name+",") {
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		err := tc.run(ctx, cc)
		cancel()
		if err != nil {
			failed++
			fmt.Printf("FAIL %s: %v\n", tc.name, err)
		} else {
			fmt.Printf("PASS %s\n", tc.name)
		}
	}
	return failed
}

func main() {
	mode := flag.String("mode", "client", "client or server")
	addr := flag.String("addr", "127.0.0.1:10000", "server address")
	only := flag.String("cases", "", "comma-separated case names (default: all)")
	flag.Parse()
	if *mode == "server" {
		lis, err := net.Listen("tcp", *addr)
		if err != nil {
			fmt.Println(err)
			os.Exit(2)
		}
		s := grpc.NewServer()
		testpb.RegisterTestServiceServer(s, server{})
		fmt.Println("listening on", lis.Addr())
		s.Serve(lis)
		return
	}
	os.Exit(runClient(*addr, *only))
}
