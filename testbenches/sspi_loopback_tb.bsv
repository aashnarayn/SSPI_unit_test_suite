/*
================================================================================
 sspi_loopback_tb.bsv - single-instance FULL_DUPLEX self-loopback testbench
================================================================================

Covers three of the five applications in application_examples/, all of which
use ONE SSPI in FULL_DUPLEX with the board shorting MOSI to MISO, so the
instance receives back exactly what it transmits (loopback connection)

    sspi_full_duplex.c   example of a full duplex connection, transmits and receives msb first as the default
    sspi_MSB_check.c     in effect the same as sspi_full_duplex.c, but specifies msb_first transmission explicitly
    sspi_LSB_check.c     exhibits the lsb_first transmission option of the full duplex connection

The companion sspi_simplex_tb.bsv covers the other two, which use two
cross-connected instances.

NOTE - these testbenches are modelled on the C testcases in GCSDK, meant to 
provide an rtl level verification of thee xact same behaviour. They have been built in the same
structure as the C testcases, so the sequence of writes and reads is identical, and the same
data is used (however this can be changed with the --data flag when running run_sspi_tb.sh)

SEQUENCE - one register access per driver call, in the C testcase's order.
Only one instance exists, so there is no arm/start split: the single DUT is
both transmitter and receiver.

  1  print the instance's comm_status / fifo_status
  2  configure it, spi_en = 0              sspi_configure()
  3  print "BF" status                      (before filling)
  4  push TB_NBYTES bytes into TX           data_tx = spi1_tx[i], one byte each
  5  print "AF" status                      (after filling)
  6  start the transfer, three writes:     sspi_configure_tx_rx_length(N*8, N*8)
                                           sspi_configure_comm_mode(FULL_DUPLEX)
                                           sspi_enable_txrx(ENABLE)
  7  wait for the transfer
  8  if RXNE set, read TB_NBYTES bytes from data_rx one at a time
  9  print each byte and compare against what was sent

Both lengths are N*8 here, unlike the simplex testbench where one side gets 0:
FULL_DUPLEX transmits and receives the same number of bits, and with MOSI
shorted to MISO those are the same bits.

DELIBERATE DIFFERENCES from the C testcase, all verified not to change what the
DUT sees:
  * sspi_clear_fifo() is omitted. sspi_full_duplex.c calls it twice - once
    before sspi_configure() and once after - but reset fifo_status reads 0x11
    (TX_EMPTY | RX_EMPTY), so both of its while loops are skipped both times.
    A no-op on a freshly reset DUT.
  * sspi_notbusy() polling is replaced by a fixed wait. Reads of
    Communication_status and FIFO_status are side-effect-free in mav_read_req
    (only RX_data_rg dequeues), and a rule polling every cycle would trip the
    scheduling hazard described below.
  * sspi_configure_clock() is not modelled: it writes (uint8_t)clk_rate into
    the prescale field, which sspi_configure_clock_in_hz() overwrites on the
    very next call. Dead write.
  * The "BF" and "AF" status reads are added for traceability. Only
    sspi_MSB_check.c prints statuses around the transfer; sspi_full_duplex.c
    does not. They are safe to add because status reads have no side effects.
  * TB_GAP cycles separate consecutive data_tx / data_rx accesses. Load/store
    latency supplies this spacing for free on hardware.

PIN CONNECTION - Ifc_sspi_io is (*always_ready, always_enabled*), so every
*_in method must be called on every cycle even when that pin is an output
here. Only one of the four lines in rl_connect_pins carries real data:

    miso_in(mosi_out)   <- the board-level short; this is the loopback
    mosi_in(mosi_out)      MOSI is an output (mosi_outen=1); value unused
    sclk_in(sclk_out)      SCLK is an output (sclk_outen=1); value unused
    ncs_in0(ncs_out0)      NCS  is an output (ncs_outen=1);  value unused

  With mosi_outen=1 and miso_outen=0 the instance drives MOSI and samples
  MISO, so feeding mosi_out back into miso_in puts its own transmit data into
  its receive path. Driving the three output pins' inputs from their own
  outputs keeps rl_si_qualification and rl_mi_qualification from both driving
  wr_spi_in_qual, which they would if the enables disagreed.

TIMING NOTES (these are why reads/writes are spaced out)
  * A write to TX_data_rg only sets rg_txdata_to_txfifo; the byte reaches the
    FIFO in rl_transfer_data_from_txreg_to_txfifo one cycle later. Writing on
    back-to-back cycles overwrites rg_tx_data before it is consumed, so the
    fill loop leaves TB_GAP cycles between bytes to simulate that needed delay.
  * A read of RX_data_rg dequeues and returns rg_rx_data, which is reloaded
    from the FIFO by rl_transfer_data_from_rxfifo_to_rxreg one cycle AFTER the
    read. Back-to-back reads therefore return stale bytes; the drain loop also
    leaves TB_GAP cycles between reads. On real hardware the delay in
    processing load/store instructions given in the C code provides this
    spacing for free.
  * Any TB rule that calls mav_read_req is scheduled more urgent than the DUT
    rules it shares state with, so a rule enabled every cycle can block
    rl_transfer_data_from_rxfifo_to_rxreg forever. i.e. rg_rx_data never loads
    and every read returns zero while succ still reads back 1. Every rule here
    that touches the DUT is a one-shot, guarded on both state and a gap
    counter - rl_fill_gap and rl_drain_gap exist solely to keep the counter
    decrement out of the rule that touches the DUT.

BYTE EXTRACTION - mav_read_req places the byte differently by bit order. For
MSB_FIRST a size-0 read returns duplicate(rg_rx_data[31:24]); for LSB_FIRST it
returns duplicate(rg_rx_data) whole, with the oldest byte in [7:0]. rl_drain_rx
selects on lsbfirst accordingly. This is a read-path quirk of the RTL, not a
difference in what was transmitted.

sspi_configure_pins(inst, 1, 0, 1, 1) for a MASTER gives mosi_outen=1 and
miso_outen=0, so the instance drives MOSI and samples MISO. Shorting them
feeds its own transmit data straight back into its receive path, which is
what the FPGA jumper does in the C testcases when testing with openocd and gdb. 
No second instance exists, so nothing else drives any pin.


================================================================================
*/
package sspi_loopback_tb;

  import sspi   :: *;
  import Vector :: *;

`include "sspi.defines"
`include "sspi_tb_config.bsvi"

  module mkTest (Empty);

    // sspi.h: SIMPLEX_TX 0, SIMPLEX_RX 1, HALF_DUPLEX 2, FULL_DUPLEX 3
    Bit#(2) full_duplex = 2'b11;  // this is fixed for this testbench

    Ifc_sspi#(8, 32) dut <- mk_sspi();

    Integer  nbytes   = `TB_NBYTES;
    Bit#(8)  totbits  = fromInteger(`TB_NBYTES * `TB_DATA_SIZE);
    bit      lsbfirst = `TB_LSB_FIRST;

    Vector#(MaxBytes, Bit#(8)) tx_data = fn_tb_tx_data();

    // Phase 1: sspi_configure() - pins, master, bit order, SPI_ENABLE clear.
    // comm_mode is untouched here, exactly as the driver's sspi_configure()
    // leaves it; rg_comm_mode holds its reset value 2'b00 until phase 2.
    Bit#(32) cfg_off = fn_comm_ctrl(True, 2'b00, 0, 0, lsbfirst, 0);

    // Phase 2 - one write per driver call, in the C testcase's order:
    //   sspi_configure_tx_rx_length(inst, N*8, N*8)
    //   sspi_configure_comm_mode(inst, FULL_DUPLEX)
    //   sspi_enable_txrx(inst, ENABLE)
    Bit#(32) cfg_len  = fn_comm_ctrl(True, 2'b00,      totbits, totbits, lsbfirst, 0);
    Bit#(32) cfg_mode = fn_comm_ctrl(True, full_duplex, totbits, totbits, lsbfirst, 0);
    Bit#(32) cfg_en   = fn_comm_ctrl(True, full_duplex, totbits, totbits, lsbfirst, 1);
    Bit#(32) clk_cfg = fn_clk_ctrl(`TB_HOLD, `TB_SETUP, `TB_PRESCALE,
                                   `TB_CPHA, `TB_CPOL);

`ifdef TB_WAIT
    Bit#(32) wait_cycles = `TB_WAIT;
`else
    // Setup and hold are counted in SCLK EDGES, so each costs a bit period.
    Bit#(32) wait_cycles = 400 + fromInteger(`TB_NBYTES * `TB_DATA_SIZE)
                                 * (`TB_PRESCALE + 1) * 2
                               + (`TB_SETUP + `TB_HOLD) * (`TB_PRESCALE + 1) * 2;
`endif

    Bit#(2) sz_byte = 2'b00;   // uint8_t  data_tx / data_rx / *_status
    Bit#(2) sz_word = 2'b10;   // uint32_t comm_control / clk_control

    Reg#(Bit#(5))  state   <- mkReg(0);
    Reg#(Bit#(32)) counter <- mkReg(0);
    Reg#(Bit#(8))  idx     <- mkReg(0);
    Reg#(Bit#(8))  gap     <- mkReg(0);
    Reg#(Bit#(8))  nerr    <- mkReg(0);
    Vector#(MaxBytes, Reg#(Bit#(8))) rx_bytes <- replicateM(mkReg(0));

    // the board-level MOSI->MISO connection
    // Ifc_sspi_io is (*always_ready, always_enabled*), so every *_in method
    // must be called every cycle even when its pin is an output here.
    rule rl_connect_pins;
      dut.subifc_io.miso_in(dut.subifc_io.mosi_out);   // <-- the loopback

      dut.subifc_io.mosi_in(dut.subifc_io.mosi_out);   // unused, but must be called
      dut.subifc_io.sclk_in(dut.subifc_io.sclk_out);   // unused
      dut.subifc_io.ncs_in0(dut.subifc_io.ncs_out0);   // unused
    endrule

    // test sequence
    rule rl_banner (state == 0 && counter == 0);
      $display("================================================================");
      $display(" SSPI loopback testbench - FULL_DUPLEX, Loopback connection (MOSI->MISO)");
      $display("   models     : sspi_full_duplex.c / sspi_MSB_check.c / sspi_LSB_check.c");
      $display("   nbytes     : %0d  (%0d bits each way)", nbytes, totbits);
      $display("   cpol / cpha: %0d / %0d", `TB_CPOL, `TB_CPHA);
      $display("   bit order  : %s", lsbfirst == 1 ? "LSB_FIRST" : "MSB_FIRST");
      $display("   prescale   : %0d  (bit period %0d cycles)",
               `TB_PRESCALE, `TB_PRESCALE + 1);
      $display("   setup/hold : %0d / %0d", `TB_SETUP, `TB_HOLD);
      $display("   settle wait: %0d cycles", wait_cycles);
      $display("================================================================");
    endrule

    rule rl_reset_wait (state == 0);
      if (counter == 10) begin state <= 1; counter <= 0; end
      else counter <= counter + 1;
    endrule

    rule rl_status_initial (state == 1);
      let c <- dut.mav_read_req(`Communication_status, sz_byte);
      let f <- dut.mav_read_req(`FIFO_status, sz_byte);
      $display($time, " dut comm_status=%h fifo_status=%h",
               tpl_2(c)[7:0], tpl_2(f)[7:0]);
      state <= 2;
    endrule

    rule rl_cfg (state == 2);
      let a <- dut.mav_write_req(`Clock_control, clk_cfg, sz_word);
      let b <- dut.mav_write_req(`Communication_control, cfg_off, sz_word);
      $display($time, " cfg dut : clk=%h comm=%h ok=%b%b", clk_cfg, cfg_off, a, b);
      state <= 3;
      idx   <= 0;
      gap   <= 0;
    endrule

    rule rl_status_bf (state == 3);
      let f <- dut.mav_read_req(`FIFO_status, sz_byte);
      $display($time, " BF fill : fifo=%h", tpl_2(f)[7:0]);
      state <= 4;
    endrule

    // Fill the TX FIFO one byte per TB_GAP cycles. Gap counter in its own rule
    // so this one is not enabled every cycle and cannot starve the DUT.
    rule rl_fill_gap (state == 4 && gap != 0);
      gap <= gap - 1;
    endrule

    rule rl_fill_tx (state == 4 && gap == 0 && idx < fromInteger(nbytes));
      let a <- dut.mav_write_req(`TX_data_rg, zeroExtend(tx_data[idx]), sz_byte);
      $display($time, " dut data_tx[%0d] <= %h ok=%b", idx, tx_data[idx], a);
      idx <= idx + 1;
      gap <= `TB_GAP;
    endrule

    rule rl_fill_done (state == 4 && gap == 0 && idx >= fromInteger(nbytes));
      state <= 5;
      idx   <= 0;
    endrule

    rule rl_status_af (state == 5);
      let f <- dut.mav_read_req(`FIFO_status, sz_byte);
      let c <- dut.mav_read_req(`Communication_status, sz_byte);
      $display($time, " AF fill : fifo=%h comm=%h", tpl_2(f)[7:0], tpl_2(c)[7:0]);
      state <= 6;
    endrule

    // tx_rx_length, then comm_mode, then enable - three writes, as in C.
    rule rl_len (state == 6);
      let a <- dut.mav_write_req(`Communication_control, cfg_len, sz_word);
      $display($time, " dut tx_rx_length(%0d,%0d): comm=%h ok=%b",
               totbits, totbits, cfg_len, a);
      state <= 7;
    endrule

    rule rl_mode (state == 7);
      let a <- dut.mav_write_req(`Communication_control, cfg_mode, sz_word);
      $display($time, " dut comm_mode(FULL_DUPLEX): comm=%h ok=%b", cfg_mode, a);
      state <= 8;
    endrule

    rule rl_enable (state == 8);
      let a <- dut.mav_write_req(`Communication_control, cfg_en, sz_word);
      $display($time, " dut enable_txrx(ENABLE)  : comm=%h ok=%b", cfg_en, a);
      state   <= 9;
      counter <= 0;
    endrule

    rule rl_wait (state == 9);
      if (counter >= wait_cycles) begin state <= 10; counter <= 0; end
      else counter <= counter + 1;
    endrule

    rule rl_check_rxne (state == 10);
      let c <- dut.mav_read_req(`Communication_status, sz_byte);
      let f <- dut.mav_read_req(`FIFO_status, sz_byte);
      Bit#(8) cs = tpl_2(c)[7:0];
      $display($time, " dut comm_status=%h fifo_status=%h (RXNE=%b BUSY=%b)",
               cs, tpl_2(f)[7:0], cs[2], cs[0]);
      // sspi.h: SPI_RXNE = (1<<2); the C testcase gates its read on 0x4.
      if ((cs & 8'h04) != 0) begin
        state <= 11;
        idx   <= 0;
        gap   <= 0;
      end
      else begin
        $display(" Did not receive any data ");
        $display("TEST FAILED");
        $finish();
      end
    endrule

    rule rl_drain_gap (state == 11 && gap != 0);
      gap <= gap - 1;
    endrule

    // mav_read_req places the byte differently per bit order: MSB_FIRST gives
    // duplicate(rg_rx_data[31:24]), LSB_FIRST gives the whole word with the
    // oldest byte in [7:0].
    rule rl_drain_rx (state == 11 && gap == 0 && idx < fromInteger(nbytes));
      let r <- dut.mav_read_req(`RX_data_rg, sz_byte);
      Bit#(8) b = lsbfirst == 1 ? tpl_2(r)[7:0] : tpl_2(r)[31:24];
      rx_bytes[idx] <= b;
      if (!tpl_1(r)) begin
        $display($time, " dut data_rx[%0d] read FAILED (succ=0)", idx);
        nerr <= nerr + 1;
      end
      idx <= idx + 1;
      gap <= `TB_GAP;
    endrule

    rule rl_drain_done (state == 11 && gap == 0 && idx >= fromInteger(nbytes));
      state <= 12;
    endrule

    rule rl_report (state == 12);
      $display(" SSPI READ VALUES (loopback - should equal what was sent)");
      Bit#(8) bad = 0;
      for (Integer i = 0; i < valueOf(MaxBytes); i = i + 1)
        if (i < nbytes) begin
          Bit#(8) exp = tx_data[i];
          Bit#(8) got = rx_bytes[i];
          $display("   rx[%0d]: %h   sent: %h   %s", i, got, exp,
                   got == exp ? "ok" : "MISMATCH");
          if (got != exp) bad = bad + 1;
        end
      $display(" %0d of %0d bytes mismatched", bad, nbytes);
      if (bad == 0 && nerr == 0) $display("TEST PASSED");
      else                       $display("TEST FAILED");
      $finish();
    endrule

  endmodule : mkTest
endpackage
