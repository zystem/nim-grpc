// Interop peer built on grpc-go: a grpc.testing.TestService server and a
// client that runs the interop test cases (doc/interop-test-descriptions.md
// in grpc/grpc) against any server.
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/keepalive"
	_ "google.golang.org/grpc/encoding/gzip"
	testpb "google.golang.org/grpc/interop/grpc_testing"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

var probe = new(bool)
var kaSeconds = new(int)

var (
	reqSizes  = []int{27182, 8, 1828, 45904}
	respSizes = []int32{31415, 9, 2653, 58979}
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
	if in.GetResponseCompressed().GetValue() {
		grpc.SetSendCompressor(ctx, "gzip")
	}
	return &testpb.SimpleResponse{
		Payload: &testpb.Payload{Body: make([]byte, in.GetResponseSize())},
	}, nil
}

func (server) StreamingOutputCall(in *testpb.StreamingOutputCallRequest, s testpb.TestService_StreamingOutputCallServer) error {
	for _, p := range in.GetResponseParameters() {
		// grpc-go compresses a whole stream or none of it.
		if p.GetCompressed().GetValue() {
			grpc.SetSendCompressor(s.Context(), "gzip")
		}
	}
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
	{"keepalive_idle", func(ctx context.Context, cc *grpc.ClientConn) error {
		// Not an official case: with -keepalive N the channel pings an idle
		// server; the connection must survive and the next call work.
		if *kaSeconds == 0 {
			return nil
		}
		c := testpb.NewTestServiceClient(cc)
		if _, err := c.EmptyCall(ctx, &testpb.Empty{}); err != nil {
			return err
		}
		time.Sleep(time.Duration(*kaSeconds*2+1) * time.Second)
		if s := cc.GetState().String(); s != "READY" && s != "IDLE" {
			return fmt.Errorf("connection state %s after pinging", s)
		}
		_, err := c.EmptyCall(ctx, &testpb.Empty{})
		return err
	}},
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
		s, err := testpb.NewTestServiceClient(cc).FullDuplexCall(ctx)
		if err == nil {
			err = s.Send(&testpb.StreamingOutputCallRequest{Payload: &testpb.Payload{Body: make([]byte, 27182)}})
			if err == nil || err == io.EOF {
				_, err = s.Recv()
			}
		}
		return expectCode(err, codes.DeadlineExceeded, "")
	}},
	{"client_compressed_unary", func(ctx context.Context, cc *grpc.ClientConn) error {
		c := testpb.NewTestServiceClient(cc)
		req := &testpb.SimpleRequest{ResponseSize: 314159, Payload: &testpb.Payload{Body: make([]byte, 271828)},
			ExpectCompressed: &testpb.BoolValue{Value: true}}
		if *probe { // the server must notice an uncompressed request
			if err := expectCode(func() error { _, err := c.UnaryCall(ctx, req); return err }(), codes.InvalidArgument, ""); err != nil {
				return fmt.Errorf("probe: %v", err)
			}
		}
		r, err := c.UnaryCall(ctx, req, grpc.UseCompressor("gzip"))
		if err != nil {
			return err
		}
		if len(r.GetPayload().GetBody()) != 314159 {
			return fmt.Errorf("payload size")
		}
		return nil
	}},
	{"server_compressed_unary", func(ctx context.Context, cc *grpc.ClientConn) error {
		// grpc-go cannot tell whether a response arrived compressed; this
		// checks that a compressed response decodes.
		for _, comp := range []bool{true, false} {
			r, err := testpb.NewTestServiceClient(cc).UnaryCall(ctx, &testpb.SimpleRequest{
				ResponseSize: 314159, ResponseCompressed: &testpb.BoolValue{Value: comp}})
			if err != nil {
				return err
			}
			if len(r.GetPayload().GetBody()) != 314159 {
				return fmt.Errorf("payload size")
			}
		}
		return nil
	}},
	{"client_compressed_streaming", func(ctx context.Context, cc *grpc.ClientConn) error {
		// grpc-go compresses all messages of a stream or none: both say so.
		s, err := testpb.NewTestServiceClient(cc).StreamingInputCall(ctx, grpc.UseCompressor("gzip"))
		if err != nil {
			return err
		}
		for _, n := range []int{27182, 45904} {
			if err := s.Send(&testpb.StreamingInputCallRequest{Payload: &testpb.Payload{Body: make([]byte, n)},
				ExpectCompressed: &testpb.BoolValue{Value: true}}); err != nil {
				return err
			}
		}
		r, err := s.CloseAndRecv()
		if err != nil {
			return err
		}
		if r.GetAggregatedPayloadSize() != 73086 {
			return fmt.Errorf("aggregated %d", r.GetAggregatedPayloadSize())
		}
		return nil
	}},
	{"server_compressed_streaming", func(ctx context.Context, cc *grpc.ClientConn) error {
		s, err := testpb.NewTestServiceClient(cc).StreamingOutputCall(ctx, &testpb.StreamingOutputCallRequest{
			ResponseParameters: []*testpb.ResponseParameters{
				{Size: 31415, Compressed: &testpb.BoolValue{Value: true}},
				{Size: 92653, Compressed: &testpb.BoolValue{Value: false}}}})
		if err != nil {
			return err
		}
		for _, n := range []int{31415, 92653} {
			r, err := s.Recv()
			if err != nil {
				return err
			}
			if len(r.GetPayload().GetBody()) != n {
				return fmt.Errorf("size %d", len(r.GetPayload().GetBody()))
			}
		}
		if _, err := s.Recv(); err != io.EOF {
			return fmt.Errorf("want EOF, got %v", err)
		}
		return nil
	}},
	{"client_streaming", func(ctx context.Context, cc *grpc.ClientConn) error {
		s, err := testpb.NewTestServiceClient(cc).StreamingInputCall(ctx)
		if err != nil {
			return err
		}
		for _, n := range reqSizes {
			if err := s.Send(&testpb.StreamingInputCallRequest{Payload: &testpb.Payload{Body: make([]byte, n)}}); err != nil {
				return err
			}
		}
		r, err := s.CloseAndRecv()
		if err != nil {
			return err
		}
		if r.GetAggregatedPayloadSize() != 74922 {
			return fmt.Errorf("aggregated %d", r.GetAggregatedPayloadSize())
		}
		return nil
	}},
	{"server_streaming", func(ctx context.Context, cc *grpc.ClientConn) error {
		req := &testpb.StreamingOutputCallRequest{}
		for _, n := range respSizes {
			req.ResponseParameters = append(req.ResponseParameters, &testpb.ResponseParameters{Size: n})
		}
		s, err := testpb.NewTestServiceClient(cc).StreamingOutputCall(ctx, req)
		if err != nil {
			return err
		}
		for _, n := range respSizes {
			r, err := s.Recv()
			if err != nil {
				return err
			}
			if len(r.GetPayload().GetBody()) != int(n) {
				return fmt.Errorf("size %d, want %d", len(r.GetPayload().GetBody()), n)
			}
		}
		if _, err := s.Recv(); err != io.EOF {
			return fmt.Errorf("want EOF, got %v", err)
		}
		return nil
	}},
	{"ping_pong", func(ctx context.Context, cc *grpc.ClientConn) error {
		s, err := testpb.NewTestServiceClient(cc).FullDuplexCall(ctx)
		if err != nil {
			return err
		}
		for i := range reqSizes {
			if err := s.Send(&testpb.StreamingOutputCallRequest{
				ResponseParameters: []*testpb.ResponseParameters{{Size: respSizes[i]}},
				Payload:            &testpb.Payload{Body: make([]byte, reqSizes[i])},
			}); err != nil {
				return err
			}
			r, err := s.Recv()
			if err != nil {
				return err
			}
			if len(r.GetPayload().GetBody()) != int(respSizes[i]) {
				return fmt.Errorf("size %d", len(r.GetPayload().GetBody()))
			}
		}
		s.CloseSend()
		if _, err := s.Recv(); err != io.EOF {
			return fmt.Errorf("want EOF, got %v", err)
		}
		return nil
	}},
	{"empty_stream", func(ctx context.Context, cc *grpc.ClientConn) error {
		s, err := testpb.NewTestServiceClient(cc).FullDuplexCall(ctx)
		if err != nil {
			return err
		}
		s.CloseSend()
		if _, err := s.Recv(); err != io.EOF {
			return fmt.Errorf("want EOF, got %v", err)
		}
		return nil
	}},
	{"cancel_after_begin", func(ctx context.Context, cc *grpc.ClientConn) error {
		ctx, cancel := context.WithCancel(ctx)
		s, err := testpb.NewTestServiceClient(cc).StreamingInputCall(ctx)
		if err != nil {
			return err
		}
		cancel()
		_, err = s.CloseAndRecv()
		return expectCode(err, codes.Canceled, "")
	}},
	{"cancel_after_first_response", func(ctx context.Context, cc *grpc.ClientConn) error {
		ctx, cancel := context.WithCancel(ctx)
		s, err := testpb.NewTestServiceClient(cc).FullDuplexCall(ctx)
		if err != nil {
			return err
		}
		if err := s.Send(&testpb.StreamingOutputCallRequest{
			ResponseParameters: []*testpb.ResponseParameters{{Size: 31415}},
			Payload:            &testpb.Payload{Body: make([]byte, 27182)},
		}); err != nil {
			return err
		}
		if _, err := s.Recv(); err != nil {
			return err
		}
		cancel()
		_, err = s.Recv()
		return expectCode(err, codes.Canceled, "")
	}},
	{"status_code_and_message_duplex", func(ctx context.Context, cc *grpc.ClientConn) error {
		msg := "test status message"
		s, err := testpb.NewTestServiceClient(cc).FullDuplexCall(ctx)
		if err != nil {
			return err
		}
		s.Send(&testpb.StreamingOutputCallRequest{ResponseStatus: &testpb.EchoStatus{Code: 2, Message: msg}})
		s.CloseSend()
		_, err = s.Recv()
		return expectCode(err, codes.Unknown, msg)
	}},
	{"custom_metadata_duplex", func(ctx context.Context, cc *grpc.ClientConn) error {
		ctx = metadata.AppendToOutgoingContext(ctx,
			initialKey, "test_initial_metadata_value",
			trailingKey, string([]byte{0xab, 0xab, 0xab}))
		s, err := testpb.NewTestServiceClient(cc).FullDuplexCall(ctx)
		if err != nil {
			return err
		}
		s.Send(&testpb.StreamingOutputCallRequest{
			ResponseParameters: []*testpb.ResponseParameters{{Size: 314159}},
			Payload:            &testpb.Payload{Body: make([]byte, 271828)},
		})
		s.CloseSend()
		if _, err := s.Recv(); err != nil {
			return err
		}
		if _, err := s.Recv(); err != io.EOF {
			return fmt.Errorf("want EOF, got %v", err)
		}
		h, _ := s.Header()
		if v := h.Get(initialKey); len(v) != 1 || v[0] != "test_initial_metadata_value" {
			return fmt.Errorf("initial metadata %v", v)
		}
		if v := s.Trailer().Get(trailingKey); len(v) != 1 || !bytes.Equal([]byte(v[0]), []byte{0xab, 0xab, 0xab}) {
			return fmt.Errorf("trailing metadata %v", v)
		}
		return nil
	}},
}

func tlsConfig(mode, certs string, server bool) *tls.Config {
	if mode == "" {
		return nil
	}
	pool := x509.NewCertPool()
	ca, err := os.ReadFile(certs + "/ca.pem")
	if err != nil {
		panic(err)
	}
	pool.AppendCertsFromPEM(ca)
	cfg := &tls.Config{MinVersion: tls.VersionTLS12}
	if server {
		cert, err := tls.LoadX509KeyPair(certs+"/server.pem", certs+"/server.key")
		if err != nil {
			panic(err)
		}
		cfg.Certificates = []tls.Certificate{cert}
		if mode == "mtls" {
			cfg.ClientCAs = pool
			cfg.ClientAuth = tls.RequireAndVerifyClientCert
		}
		return cfg
	}
	cfg.RootCAs = pool
	cfg.ServerName = "localhost"
	if mode == "mtls" {
		cert, err := tls.LoadX509KeyPair(certs+"/client.pem", certs+"/client.key")
		if err != nil {
			panic(err)
		}
		cfg.Certificates = []tls.Certificate{cert}
	}
	return cfg
}

func runClient(addr, only string, tc *tls.Config) int {
	creds := insecure.NewCredentials()
	if tc != nil {
		creds = credentials.NewTLS(tc)
	}
	opts := []grpc.DialOption{grpc.WithTransportCredentials(creds)}
	if *kaSeconds > 0 {
		// grpc-go does not ping more often than every 10 s.
		opts = append(opts, grpc.WithKeepaliveParams(keepalive.ClientParameters{
			Time: time.Duration(*kaSeconds) * time.Second, Timeout: 2 * time.Second,
			PermitWithoutStream: true}))
	}
	cc, err := grpc.NewClient(addr, opts...)
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
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
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
	role := flag.String("mode", "client", "client or server")
	addr := flag.String("addr", "127.0.0.1:10000", "server address")
	only := flag.String("cases", "", "comma-separated case names (default: all)")
	mode := flag.String("tls", "", "\"\", \"tls\" or \"mtls\"")
	certs := flag.String("certs", "certs", "directory with ca.pem, server.*, client.*")
	flag.BoolVar(probe, "probe", true, "run the compression probes (the server must check expect_compressed)")
	flag.IntVar(kaSeconds, "keepalive", 0, "client keepalive time in seconds (0: off)")
	flag.Parse()
	if *role == "server" {
		lis, err := net.Listen("tcp", *addr)
		if err != nil {
			fmt.Println(err)
			os.Exit(2)
		}
		var opts []grpc.ServerOption
		if tc := tlsConfig(*mode, *certs, true); tc != nil {
			opts = append(opts, grpc.Creds(credentials.NewTLS(tc)))
		}
		s := grpc.NewServer(opts...)
		testpb.RegisterTestServiceServer(s, server{})
		fmt.Println("listening on", lis.Addr())
		s.Serve(lis)
		return
	}
	os.Exit(runClient(*addr, *only, tlsConfig(*mode, *certs, false)))
}
