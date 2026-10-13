/*
================================================================================
 sspi_simplex_tb.bsv - two-SSPI RTL testbench, modelled on the GCSDK testcases
================================================================================

Covers two of the five applications in application_examples/, and uses TWO
isntances of SSPI in cross-connected to each other. The connections are as follows:

SSPI0 MOSI <-> SSPI1 MOSI
SSPI0 MISO <-> SSPI1 MISO
SSPI0 SCLK <-> SSPI1 SCLK
SSPI0 NCS  <-> SSPI1 NCS

The model applications are:
sspi_simplex_tx.c   Two sspis in simplex tx and simplex rx mode, with focus on verifying the transmitted data
sspi_simplex_rx.c   Two sspis in simplex tx and simplex rx mode, with focus on verifying the received data

The companion sspi_loopback_tb.bsv covers the other three applications, which use one SSPI instance 
with its own MOSI and MISO in loopback connection.

The defaults below reproduce sspi_simplex_tx.c exactly:

  SSPI_SIZE 8, DATA_SIZE 8            -> 8 bytes, 64 bits total
  CLK_POLARITY_LOW, CLK_PHASE_LOW     -> TB_CPOL 0, TB_CPHA 0
  MSB_FIRST                           -> TB_LSB_FIRST 0
  SETUP_TIME_CYCLES 1, HOLD_TIME_CYCLES 0
  SSPI_CLOCK_FREQUENCY 100000         -> prescale per sspi_configure_clock_in_hz()
  spi2_tx[i] = 0x01 + i               -> 01 02 03 04 05 06 07 08
  master = SIMPLEX_TX, slave = SIMPLEX_RX


  master  <-> sspi_instance[2] (SSPIX) in sspi_simplex_tx.c - drives SCLK/NCS,
              transmits on MOSI, comm_mode SIMPLEX_TX
  slave   <-> sspi_instance[3] (SSPIY) - receives on MOSI, comm_mode SIMPLEX_RX

NOTE - these testbenches are modelled on the C testcases in GCSDK, meant to 
provide an rtl level verification of thee xact same behaviour. They have been built in the same
structure as the C testcases, so the sequence of writes and reads is identical, and the same
data is used (however this can be changed with the --data flag when running run_sspi_tb.sh)


SEQUENCE - one register access per driver call, in the C testcase's order:

  1  print both instances' comm_status / fifo_status
  2  configure both, spi_en = 0           sspi_configure()
  3  print "BF" statuses                   (before filling)
  4  push TB_NBYTES bytes into master TX   data_tx = spi2_tx[i], one byte each
  5  print "AF" statuses                   (after filling)
  6  arm the slave, three writes:         sspi_configure_tx_rx_length(0, N*8)
                                          sspi_configure_comm_mode(SIMPLEX_RX)
                                          sspi_enable_txrx(ENABLE)
  7  start the master, three writes:      sspi_configure_tx_rx_length(N*8, 0)
                                          sspi_configure_comm_mode(SIMPLEX_TX)
                                          sspi_enable_txrx(ENABLE)
  8  wait for the transfer
  9  if slave RXNE set, read TB_NBYTES bytes from data_rx one at a time
  10 print each byte and compare against what was sent

DELIBERATE DIFFERENCES from the C testcase, all verified not to change what the
DUT sees:
  * sspi_clear_fifo() is omitted. Reset fifo_status reads 0x11
    (TX_EMPTY | RX_EMPTY), so both of its while loops are skipped - it is a
    no-op on a freshly reset DUT.
  * sspi_notbusy() polling is replaced by a fixed wait. Reads of
    Communication_status and FIFO_status are side-effect-free in mav_read_req
    (only RX_data_rg dequeues), and a rule polling every cycle would trip the
    scheduling hazard described below.
  * sspi_configure_clock() is not modelled: it writes (uint8_t)clk_rate into
    the prescale field, which sspi_configure_clock_in_hz() overwrites on the
    very next call. Dead write.
  * TB_GAP cycles separate consecutive data_tx / data_rx accesses. Load/store
    latency supplies this spacing for free on hardware.

TIMING NOTES (these are why reads/writes are spaced out)
  * A write to TX_data_rg only sets rg_txdata_to_txfifo; the byte reaches the
    FIFO in rl_transfer_data_from_txreg_to_txfifo one cycle later. Writing on
    back-to-back cycles overwrites rg_tx_data before it is consumed, so the
    fill loop leaves TB_GAP cycles between bytes to simulate that needed delay.
  * A read of RX_data_rg dequeues and returns rg_rx_data, which is reloaded
    from the FIFO by rl_transfer_data_from_rxfifo_to_rxreg one cycle AFTER the
    read. Back-to-back reads therefore return stale bytes; the drain loop also
    leaves TB_GAP cycles between reads. On real hardware the delay in processing 
    load/store instructions given in the C code provide this spacing for free.
  * Any TB rule that calls mav_read_req is scheduled more urgent than the DUT
    rules it shares state with, so a rule enabled every cycle can block
    rl_transfer_data_from_rxfifo_to_rxreg forever. i.e. rg_rx_data never loads and
    every read returns zero while succ still reads back 1. Every rule here that
    touches the DUT is a one-shot, guarded on both state and a gap counter.

PIN CONFIGURATION - from sspi_configure_pins() in the testcase:
    master -> (mosi, miso, ncs, sclk) = (1, 0, 1, 1)
    slave  -> (mosi, miso, ncs, sclk) = (0, 1, 0, 0)
  The slave's miso_outen = 1 is needed even though MISO is unused in
  simplex: mk_sspi has two rules driving wr_spi_in_qual, rl_si_qualification
  (guarded on mosi_outen == 0) and rl_mi_qualification (guarded on
  miso_outen == 0), and with both enables at 0 they would both drive it.
================================================================================
*/
package sspi_simplex_tb;

  import sspi   :: *;
  import Vector :: *;

`include "sspi.defines"

// configuration
// arguments modelled from sspi header in GCSDK/bsp/include/sspi.h
// and platform.h found in bsp/third_party/<soc> (ganga)
// Defaults = sspi_simplex_tx.c. Use run_sspi_tb.sh 
// with different flags or use bsc -D

`include "sspi_tb_config.bsvi"


  module mkTest (Empty);

    // SIMPLEX_TX = 0, SIMPLEX_RX = 1, HALF_DUPLEX = 2, FULL_DUPLEX = 3 (sspi.h)
    Bit#(2) simplex_tx = 2'b00;  // these two comm_mode configs are fixed for this testbench
    Bit#(2) simplex_rx = 2'b01;

    Ifc_sspi#(8, 32) master <- mk_sspi();   // sspi_instance[2], clocks the bus
    Ifc_sspi#(8, 32) slave  <- mk_sspi();   // sspi_instance[3], receives

    Integer  nbytes   = `TB_NBYTES;
    Bit#(8)  totbits  = fromInteger(`TB_NBYTES * `TB_DATA_SIZE);
    bit      lsbfirst = `TB_LSB_FIRST;

    Vector#(MaxBytes, Bit#(8)) tx_data = fn_tb_tx_data();

    // Phase 1: sspi_configure() - pins, master/slave, bit order, no enable.
    Bit#(32) cfg_master_off = fn_comm_ctrl(True,  2'b00, 0, 0, lsbfirst, 0);
    Bit#(32) cfg_slave_off  = fn_comm_ctrl(False, 2'b00, 0, 0, lsbfirst, 0);

    // Phase 2 - one register write per driver call, in the driver's order:
    //   sspi_configure_tx_rx_length(inst, tx_length, rx_length)
    //   sspi_configure_comm_mode(inst, mode)
    //   sspi_enable_txrx(inst, ENABLE)
    Bit#(32) slv_len   = fn_comm_ctrl(False, 2'b00,     totbits, 0, lsbfirst, 0);
    Bit#(32) slv_mode  = fn_comm_ctrl(False, simplex_rx, totbits, 0, lsbfirst, 0);
    Bit#(32) slv_en    = fn_comm_ctrl(False, simplex_rx, totbits, 0, lsbfirst, 1);

    Bit#(32) mas_len   = fn_comm_ctrl(True,  2'b00,     0, totbits, lsbfirst, 0);
    Bit#(32) mas_mode  = fn_comm_ctrl(True,  simplex_tx, 0, totbits, lsbfirst, 0);
    Bit#(32) mas_en    = fn_comm_ctrl(True,  simplex_tx, 0, totbits, lsbfirst, 1);

    Bit#(32) clk_cfg        = fn_clk_ctrl(`TB_HOLD, `TB_SETUP, `TB_PRESCALE,
                                          `TB_CPHA, `TB_CPOL);

    // Settle time: each bit costs about (prescale+1) cycles.
`ifdef TB_WAIT
    Bit#(32) wait_cycles = `TB_WAIT;
`else
    // Setup and hold are counted in SCLK EDGES (rl_set_up_time /
    // rl_abort_condition advance their counters on wr_write_en), so each one
    // costs a bit period, not a handful of cycles.
    Bit#(32) wait_cycles = 400 + fromInteger(`TB_NBYTES * `TB_DATA_SIZE)
                                 * (`TB_PRESCALE + 1) * 2
                               + (`TB_SETUP + `TB_HOLD) * (`TB_PRESCALE + 1) * 2;
`endif

    Bit#(2) sz_byte = 2'b00;   // uint8_t  data_tx / data_rx / *_status
    Bit#(2) sz_half = 2'b01;   // uint16_t intr_en
    Bit#(2) sz_word = 2'b10;   // uint32_t comm_control / clk_control

    Reg#(Bit#(5))  state   <- mkReg(0);
    Reg#(Bit#(32)) counter <- mkReg(0);
    Reg#(Bit#(8))  idx     <- mkReg(0);
    Reg#(Bit#(8))  gap     <- mkReg(0);
    Reg#(Bit#(8))  nerr    <- mkReg(0);
    Vector#(MaxBytes, Reg#(Bit#(8))) rx_bytes <- replicateM(mkReg(0));

    // pin level connection
    // Ifc_sspi_io is (*always_ready, always_enabled*), so every input method must
    // be called every cycle. refer wiring in TbSoc.bsv in gc2025

    // additional delay registers and rules for pipelining the sspi sclk and ncs 
    // from master to slave - used for debug
    Reg#(bit) d1_sclk <- mkRegA(0);
    Reg#(bit) d1_mosi <- mkRegA(0);
    Reg#(bit) d1_ncs  <- mkRegA(1);
    Reg#(bit) d2_sclk <- mkRegA(0);
    Reg#(bit) d2_mosi <- mkRegA(0);
    Reg#(bit) d2_ncs  <- mkRegA(1);

    // rule rl_io_delay1;
      // d1_sclk <= master.subifc_io.sclk_out;
      // d1_ncs  <= master.subifc_io.ncs_out0;
      // d1_mosi <= master.subifc_io.mosi_out;
    // endrule

    // rule rl_io_delay2;
      // d2_sclk <= d1_sclk;
      // d2_ncs  <= d1_ncs;  
      // d2_mosi <= d1_mosi;
    // endrule

    rule rl_connect_pins;
      // slave.subifc_io.sclk_in(d2_sclk);          // delayed by 2 cycles
      // slave.subifc_io.ncs_in0(d2_ncs);           // delayed by 2 cycles
      // slave.subifc_io.mosi_in(d2_mosi);          // delayed by 2 cycles
      slave.subifc_io.sclk_in(master.subifc_io.sclk_out);
      slave.subifc_io.ncs_in0(master.subifc_io.ncs_out0);
      slave.subifc_io.mosi_in(master.subifc_io.mosi_out);
      slave.subifc_io.miso_in(master.subifc_io.miso_out);
      master.subifc_io.sclk_in(slave.subifc_io.sclk_out);
      master.subifc_io.ncs_in0(slave.subifc_io.ncs_out0);
      master.subifc_io.mosi_in(slave.subifc_io.mosi_out);
      master.subifc_io.miso_in(slave.subifc_io.miso_out);
    endrule


    // test sequence
    rule rl_banner (state == 0 && counter == 0);
      $display("================================================================");
      $display(" SSPI RTL testbench - modelled on GCSDK sspi_simplex_tx.c");
      $display("   roles       : master=SIMPLEX_TX  slave=SIMPLEX_RX");
      $display("   nbytes      : %0d  (%0d bits total)", nbytes, totbits);
      $display("   cpol / cpha : %0d / %0d", `TB_CPOL, `TB_CPHA);
      $display("   bit order   : %s", lsbfirst == 1 ? "LSB_FIRST" : "MSB_FIRST");
      $display("   prescale    : %0d  (bit period %0d cycles)",
               `TB_PRESCALE, `TB_PRESCALE + 1);
      $display("   setup/hold  : %0d / %0d", `TB_SETUP, `TB_HOLD);
      $display("   settle wait : %0d cycles", wait_cycles);
      $display("================================================================");
    endrule

    rule rl_reset_wait (state == 0);
      if (counter == 10) begin state <= 1; counter <= 0; end
      else counter <= counter + 1;
    endrule

    // 1: initial status, as the testcase prints before anything else
    rule rl_status_initial (state == 1);
      let mc <- master.mav_read_req(`Communication_status, sz_byte);
      let mf <- master.mav_read_req(`FIFO_status, sz_byte);
      $display($time, " master comm_status=%h fifo_status=%h",
               tpl_2(mc)[7:0], tpl_2(mf)[7:0]);
      state <= 2;
    endrule

    rule rl_status_initial2 (state == 2);
      let sc <- slave.mav_read_req(`Communication_status, sz_byte);
      let sf <- slave.mav_read_req(`FIFO_status, sz_byte);
      $display($time, " slave  comm_status=%h fifo_status=%h",
               tpl_2(sc)[7:0], tpl_2(sf)[7:0]);
      state <= 3;
    endrule

    // 2: sspi_configure() on both, SPI_ENABLE clear
    rule rl_cfg_slave (state == 3);
      let a <- slave.mav_write_req(`Clock_control, clk_cfg, sz_word);
      let b <- slave.mav_write_req(`Communication_control, cfg_slave_off, sz_word);
      $display($time, " cfg slave : clk=%h comm=%h ok=%b%b", clk_cfg, cfg_slave_off, a, b);
      state <= 4;
    endrule

    rule rl_cfg_master (state == 4);
      let a <- master.mav_write_req(`Clock_control, clk_cfg, sz_word);
      let b <- master.mav_write_req(`Communication_control, cfg_master_off, sz_word);
      $display($time, " cfg master: clk=%h comm=%h ok=%b%b", clk_cfg, cfg_master_off, a, b);
      state <= 5;
      idx   <= 0;
      gap   <= 0;
    endrule

    // 3. status before, then fill the master TX FIFO
    rule rl_status_bf (state == 5);
      let sf <- slave.mav_read_req(`FIFO_status, sz_byte);
      let mf <- master.mav_read_req(`FIFO_status, sz_byte);
      $display($time, " BF fill : slave fifo=%h  master fifo=%h",
               tpl_2(sf)[7:0], tpl_2(mf)[7:0]);
      state <= 6;
    endrule

    // 4. One byte per TB_GAP cycles - see the timing note 
    // The gap counter lives in its OWN rule: if the DUT-touching rule were
    // enabled every cycle (to decrement the counter) it would be scheduled
    // ahead of the DUT's own rules and stall them. Split this way, it is
    // enabled on exactly one cycle in (TB_GAP+1).
    rule rl_fill_gap (state == 6 && gap != 0);
      gap <= gap - 1;
    endrule

    rule rl_fill_tx (state == 6 && gap == 0 && idx < fromInteger(nbytes));
      let a <- master.mav_write_req(`TX_data_rg,
                                    zeroExtend(tx_data[idx]), sz_byte);
      $display($time, " master data_tx[%0d] <= %h ok=%b", idx, tx_data[idx], a);
      idx <= idx + 1;
      gap <= `TB_GAP;
    endrule

    rule rl_fill_done (state == 6 && gap == 0 && idx >= fromInteger(nbytes));
      state <= 7;
      idx   <= 0;
    endrule

    // 5: status after
    rule rl_status_af (state == 7);
      let sf <- slave.mav_read_req(`FIFO_status, sz_byte);
      state <= 8;
    endrule

    rule rl_status_af2 (state == 8);
      let mf <- master.mav_read_req(`FIFO_status, sz_byte);
      let mc <- master.mav_read_req(`Communication_status, sz_byte);
      $display($time, " AF fill : master fifo=%h comm=%h",
               tpl_2(mf)[7:0], tpl_2(mc)[7:0]);
      state <= 9;
    endrule

    // 6: arm the receiver first (the testcase enables the slave first),
    //    matches this order: tx_rx_length(0, N*8), comm_mode(SIMPLEX_RX), enable.
    rule rl_slave_len (state == 9);
      let a <- slave.mav_write_req(`Communication_control, slv_len, sz_word);
      $display($time, " slave  tx_rx_length(0,%0d): comm=%h ok=%b", totbits, slv_len, a);
      state <= 10;
    endrule

    rule rl_slave_mode (state == 10);
      let a <- slave.mav_write_req(`Communication_control, slv_mode, sz_word);
      $display($time, " slave  comm_mode(SIMPLEX_RX): comm=%h ok=%b", slv_mode, a);
      state <= 11;
    endrule

    rule rl_slave_en (state == 11);
      let a <- slave.mav_write_req(`Communication_control, slv_en, sz_word);
      $display($time, " slave  enable_txrx(ENABLE) : comm=%h ok=%b", slv_en, a);
      state <= 12;
    endrule

    // 7: start the master, same write sequence
    rule rl_master_len (state == 12);
      let a <- master.mav_write_req(`Communication_control, mas_len, sz_word);
      $display($time, " master tx_rx_length(%0d,0): comm=%h ok=%b", totbits, mas_len, a);
      state <= 13;
    endrule

    rule rl_master_mode (state == 13);
      let a <- master.mav_write_req(`Communication_control, mas_mode, sz_word);
      $display($time, " master comm_mode(SIMPLEX_TX): comm=%h ok=%b", mas_mode, a);
      state <= 14;
    endrule

    rule rl_master_en (state == 14);
      let a <- master.mav_write_req(`Communication_control, mas_en, sz_word);
      $display($time, " master enable_txrx(ENABLE) : comm=%h ok=%b", mas_en, a);
      state   <= 15;
      counter <= 0;
    endrule

    // 8: wait for the transfer to complete
    rule rl_wait (state == 15);
      if (counter >= wait_cycles) begin
        state   <= 16;
        counter <= 0;
      end
      else
        counter <= counter + 1;
    endrule

    // 9: check RXNE on the instance, then drain
    rule rl_check_rxne (state == 16);
      let sc <- slave.mav_read_req(`Communication_status, sz_byte);
      let sf <- slave.mav_read_req(`FIFO_status, sz_byte);
      Bit#(8) cs = tpl_2(sc)[7:0];
      $display($time, " slave comm_status=%h fifo_status=%h (RXNE=%b BUSY=%b)",
               cs, tpl_2(sf)[7:0], cs[2], cs[0]);
      // sspi.h: SPI_RXNE = (1<<2); the testcase gates the read on 0x4.
      if ((cs & 8'h04) != 0) begin
        state <= 17;
        idx   <= 0;
        gap   <= 0;
      end
      else begin
        $display(" Did not receive any data ");
        $display("TEST FAILED");
        $finish();
      end
    endrule

    // Drain data_rx one byte per TB_GAP cycles. Split for the same reason as
    // the fill loop, needed here because a read dequeues and returns
    // rg_rx_data, which rl_transfer_data_from_rxfifo_to_rxreg reloads from the
    // FIFO one cycle later. With a rule enabled every cycle that reload never
    // fires, and every byte read back is a copy of the first one.
    rule rl_drain_gap (state == 17 && gap != 0);
      gap <= gap - 1;
    endrule

    rule rl_drain_rx (state == 17 && gap == 0 && idx < fromInteger(nbytes));
      let r <- slave.mav_read_req(`RX_data_rg, sz_byte);
      // Byte placement differs by bit order in mav_read_req: for MSB_FIRST a
      // size-0 read returns duplicate(rg_rx_data[31:24]), but for LSB_FIRST it
      // returns duplicate(rg_rx_data) whole. rg_rx_data is assembled as
      // {first[3],first[2],first[1],first[0]}, so the oldest byte is in [7:0].
      Bit#(8) b = lsbfirst == 1 ? tpl_2(r)[7:0] : tpl_2(r)[31:24];
      rx_bytes[idx] <= b;
      if (!tpl_1(r)) begin
        $display($time, " slave data_rx[%0d] read FAILED (succ=0)", idx);
        nerr <= nerr + 1;
      end
      idx <= idx + 1;
      gap <= `TB_GAP;
    endrule

    rule rl_drain_done (state == 17 && gap == 0 && idx >= fromInteger(nbytes));
      state <= 18;
    endrule

    // 10: results
    rule rl_report (state == 18);
      $display(" SSPI READ VALUES (receiving instance)");
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
      if (bad == 0 && nerr == 0)
        $display("TEST PASSED");
      else
        $display("TEST FAILED");
      $finish();
    endrule

  endmodule : mkTest
endpackage
