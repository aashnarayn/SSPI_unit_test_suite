/*
================================================================================
 sspi_half_duplex_tb.bsv - two-SSPI HALF_DUPLEX testbench, modelled on the GCSDK
 half duplex testcases
================================================================================

Covers the two remaining applications in application_examples/, both of which
cross-connect two instances and run the master in HALF_DUPLEX (comm_mode 10):

    sspi_half_duplex_MSB_check.c   master transmits, then receives, MSB first
    sspi_half_duplex_LSB_check.c   identical but LSB first

The two differ only in the bit order passed to their configure helper, so both
are reached from this one testbench, LSB with --lsb-first.

The companion sspi_simplex_tb.bsv covers the simplex pair and
sspi_loopback_tb.bsv the single-instance full duplex ones.

TOPOLOGY - the same cross connect as sspi_simplex_tb.bsv:

    master.mosi_out ----> slave.mosi_in      master drives the bus
    master.sclk_out ----> slave.sclk_in
    master.ncs_out0 ----> slave.ncs_in0
    slave.miso_out  ----> master.miso_in     slave answers on MISO

WHAT HALF DUPLEX MEANS HERE - the master transmits its whole command, and only
once the transmit phase is done does it start receiving. In the RTL that is
the `rg_comm_mode != 2'b10 || rg_transmit_state == TRANSMIT_DONE` clause on
rl_receive_idle_to_data_receive: in mode 10 the receiver will not arm until the
transmitter has finished.

The slave has no such notion. It is configured FULL_DUPLEX for the whole
exchange and shifts continuously across both phases, which is why its lengths
are the sum of the master's two:

    master  tx = HD_TX bytes, rx = HD_RX bytes,  comm_mode HALF_DUPLEX (10)
    slave   tx = rx = HD_TX + HD_RX bytes,       comm_mode FULL_DUPLEX (11)

DATA SPLIT - TB_NBYTES is the TOTAL exchanged, split in half, so the default of
8 gives 4 command bytes and 4 response bytes exactly as the C testcase does:

    HD_TX = TB_NBYTES / 2        master command bytes   tx_data[0 .. HD_TX-1]
    HD_RX = TB_NBYTES / 2        slave response bytes   tx_data[HD_TX .. ]

The slave's TX FIFO is loaded with filler first and the response second:

    slave tx = A0 A1 ... (HD_TX filler bytes)  then  tx_data[HD_TX ..]

The filler is what the slave shifts out while the master is still transmitting.
The master is not receiving then, so the filler is discarded. This mirrors
SSPI_SLAVE_FILLER_DATA in the C testcase.

SETUP TIME IS ASYMMETRIC - the C testcase gives the master the configured setup
delay and the slave zero:

    sspi_configure(slave,  ..., SLAVE,  SLAVE,      ..., 0,          hold)
    sspi_configure(master, ..., MASTER, SPI_MASTER, ..., setup_time, hold)

That asymmetry is reproduced here, so --setup only moves the master.

WHAT IS CHECKED
  * master rx must equal the slave's response bytes, tx_data[HD_TX ..]
  * slave rx, first HD_TX bytes, must equal the master's command
  * slave rx, last HD_RX bytes, are the master's held MOSI line during its
    receive phase. The C testcase prints these and does not check them, so
    neither does this one; they are reported for information.

SEQUENCE - one register access per driver call, in the C testcase's order.
Note the enables come after BOTH instances are fully configured, unlike the
simplex testbench where each side is armed and started in turn:

  1  print both instances' comm_status / fifo_status
  2  configure both, spi_en = 0           sspi_configure()
  3  print "BF" statuses                   (before filling)
  4  fill the SLAVE TX FIFO first          filler then response
  5  fill the MASTER TX FIFO               the command bytes
  6  print "AF" statuses                   (after filling)
  7  slave  length + FULL_DUPLEX          sspi_configure_tx_rx_length/comm_mode
  8  master length + HALF_DUPLEX
  9  enable the slave, then the master     sspi_enable_txrx(ENABLE)
  10 wait for both phases
  11 if master RXNE set, read HD_RX bytes and compare with the response
  12 if slave  RXNE set, read HD_TX + HD_RX bytes, compare the first HD_TX
  13 report

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
  * The idle-MOSI tail value the C testcase computes from comm_control is not
    recomputed here. The tail bytes are printed as received.
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
    leaves TB_GAP cycles between reads. On real hardware the delay in
    processing load/store instructions given in the C code provides this
    spacing for free.
  * Any TB rule that calls mav_read_req is scheduled more urgent than the DUT
    rules it shares state with, so a rule enabled every cycle can block
    rl_transfer_data_from_rxfifo_to_rxreg forever. i.e. rg_rx_data never loads
    and every read returns zero while succ still reads back 1. Every rule here
    that touches the DUT is a one-shot, guarded on both state and a gap counter.
  * The wait must cover BOTH phases plus the slave's full stream, so it is
    sized on TB_NBYTES, the total, not on either half.

PIN CONFIGURATION - from sspi_configure_pins() in the testcase:
    master -> (mosi, miso, ncs, sclk) = (1, 0, 1, 1)
    slave  -> (mosi, miso, ncs, sclk) = (0, 1, 0, 0)
  The slave's miso_outen = 1 is what lets it answer, and is also load-bearing
  for the input qualification rules: mk_sspi has two rules driving
  wr_spi_in_qual, rl_si_qualification (guarded on mosi_outen == 0) and
  rl_mi_qualification (guarded on miso_outen == 0), and with both enables at 0
  they would both drive it.
================================================================================
*/
package sspi_half_duplex_tb;

  import sspi   :: *;
  import Vector :: *;

`include "sspi.defines"

// ============================ configuration =================================
// Every knob maps to a driver call or constant in GCSDK/bsp/include/sspi.h.
// Defaults = sspi_half_duplex_MSB_check.c. Override with -D, or use
// ./run_sspi_tb.sh.

`include "sspi_tb_config.bsvi"

  module mkTest (Empty);

    // sspi.h: SIMPLEX_TX 0, SIMPLEX_RX 1, HALF_DUPLEX 2, FULL_DUPLEX 3
    Bit#(2) half_duplex = 2'b10;
    Bit#(2) full_duplex = 2'b11;

    Ifc_sspi#(8, 32) master <- mk_sspi();   // sspi_instance[0], HALF_DUPLEX
    Ifc_sspi#(8, 32) slave  <- mk_sspi();   // sspi_instance[1], FULL_DUPLEX

    // TB_NBYTES is the total exchanged; the master's command is the first
    // half and the slave's response the second.
    Integer  total    = `TB_NBYTES;
    Integer  hd_tx    = `TB_NBYTES / 2;
    Integer  hd_rx    = `TB_NBYTES - (`TB_NBYTES / 2);
    Bit#(8)  tx_bits  = fromInteger((`TB_NBYTES / 2) * `TB_DATA_SIZE);
    Bit#(8)  rx_bits  = fromInteger((`TB_NBYTES - (`TB_NBYTES / 2))
                                    * `TB_DATA_SIZE);
    Bit#(8)  slv_bits = fromInteger(`TB_NBYTES * `TB_DATA_SIZE);
    bit      lsbfirst = `TB_LSB_FIRST;

    Vector#(MaxBytes, Bit#(8)) tx_data = fn_tb_tx_data();

    // Phase 1: sspi_configure() - pins, master/slave, bit order, no enable.
    // comm_mode is NOT set here; the driver's sspi_configure() never touches
    // it, so it stays at its reset value until phase 2.
    Bit#(32) cfg_master_off = fn_comm_ctrl(True,  2'b00, 0, 0, lsbfirst, 0);
    Bit#(32) cfg_slave_off  = fn_comm_ctrl(False, 2'b00, 0, 0, lsbfirst, 0);

    // Phase 2, one register write per driver call.
    Bit#(32) slv_len  = fn_comm_ctrl(False, 2'b00,      slv_bits, slv_bits, lsbfirst, 0);
    Bit#(32) slv_mode = fn_comm_ctrl(False, full_duplex, slv_bits, slv_bits, lsbfirst, 0);
    Bit#(32) slv_en   = fn_comm_ctrl(False, full_duplex, slv_bits, slv_bits, lsbfirst, 1);

    Bit#(32) mas_len  = fn_comm_ctrl(True,  2'b00,      rx_bits, tx_bits, lsbfirst, 0);
    Bit#(32) mas_mode = fn_comm_ctrl(True,  half_duplex, rx_bits, tx_bits, lsbfirst, 0);
    Bit#(32) mas_en   = fn_comm_ctrl(True,  half_duplex, rx_bits, tx_bits, lsbfirst, 1);

    // The C testcase gives the slave zero setup delay and the master the
    // configured one.
    Bit#(32) clk_master = fn_clk_ctrl(`TB_HOLD, `TB_SETUP, `TB_PRESCALE,
                                      `TB_CPHA, `TB_CPOL);
    Bit#(32) clk_slave  = fn_clk_ctrl(`TB_HOLD, 0, `TB_PRESCALE,
                                      `TB_CPHA, `TB_CPOL);

`ifdef TB_WAIT
    Bit#(32) wait_cycles = `TB_WAIT;
`else
    // Sized on the TOTAL stream, since the slave shifts across both phases.
    // Setup and hold are counted in SCLK edges, so each costs a bit period.
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
    Vector#(MaxBytes, Reg#(Bit#(8))) mas_rx <- replicateM(mkReg(0));
    Vector#(MaxBytes, Reg#(Bit#(8))) slv_rx <- replicateM(mkReg(0));

    // ---------------- pin level cross connect ----------------------------
    // Ifc_sspi_io is (*always_ready, always_enabled*): every *_in method must
    // be called every cycle.
    rule rl_connect_pins;
      slave.subifc_io.sclk_in(master.subifc_io.sclk_out);
      slave.subifc_io.ncs_in0(master.subifc_io.ncs_out0);
      slave.subifc_io.mosi_in(master.subifc_io.mosi_out);
      slave.subifc_io.miso_in(master.subifc_io.miso_out);
      master.subifc_io.sclk_in(slave.subifc_io.sclk_out);
      master.subifc_io.ncs_in0(slave.subifc_io.ncs_out0);
      master.subifc_io.mosi_in(slave.subifc_io.mosi_out);
      master.subifc_io.miso_in(slave.subifc_io.miso_out);
    endrule

    // ============================ sequence ==============================
    rule rl_banner (state == 0 && counter == 0);
      $display("================================================================");
      $display(" SSPI HALF_DUPLEX testbench - modelled on GCSDK");
      $display("   sspi_half_duplex_%s_check.c",
               lsbfirst == 1 ? "LSB" : "MSB");
      $display("   roles       : master=HALF_DUPLEX  slave=FULL_DUPLEX");
      $display("   master      : tx %0d bytes, rx %0d bytes", hd_tx, hd_rx);
      $display("   slave       : tx=rx %0d bytes (both phases)", total);
      $display("   cpol / cpha : %0d / %0d", `TB_CPOL, `TB_CPHA);
      $display("   bit order   : %s", lsbfirst == 1 ? "LSB_FIRST" : "MSB_FIRST");
      $display("   prescale    : %0d  (bit period %0d cycles)",
               `TB_PRESCALE, `TB_PRESCALE + 1);
      $display("   setup/hold  : %0d / %0d  (slave setup forced to 0)",
               `TB_SETUP, `TB_HOLD);
      $display("   settle wait : %0d cycles", wait_cycles);
      $display("================================================================");
    endrule

    rule rl_reset_wait (state == 0);
      if (counter == 10) begin state <= 1; counter <= 0; end
      else counter <= counter + 1;
    endrule

    // --- 1: initial status ----------------------------------------------
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

    // --- 2: sspi_configure() on both, slave first, SPI_ENABLE clear ------
    rule rl_cfg_slave (state == 3);
      let a <- slave.mav_write_req(`Clock_control, clk_slave, sz_word);
      let b <- slave.mav_write_req(`Communication_control, cfg_slave_off, sz_word);
      $display($time, " cfg slave : clk=%h comm=%h ok=%b%b (setup forced 0)",
               clk_slave, cfg_slave_off, a, b);
      state <= 4;
    endrule

    rule rl_cfg_master (state == 4);
      let a <- master.mav_write_req(`Clock_control, clk_master, sz_word);
      let b <- master.mav_write_req(`Communication_control, cfg_master_off, sz_word);
      $display($time, " cfg master: clk=%h comm=%h ok=%b%b",
               clk_master, cfg_master_off, a, b);
      state <= 5;
      idx   <= 0;
      gap   <= 0;
    endrule

    // --- 3: "BF" status --------------------------------------------------
    rule rl_status_bf (state == 5);
      let sf <- slave.mav_read_req(`FIFO_status, sz_byte);
      let mf <- master.mav_read_req(`FIFO_status, sz_byte);
      $display($time, " BF fill : slave fifo=%h  master fifo=%h",
               tpl_2(sf)[7:0], tpl_2(mf)[7:0]);
      state <= 6;
    endrule

    // --- 4: fill the SLAVE TX FIFO first: filler then response ----------
    rule rl_fill_slave_gap (state == 6 && gap != 0);
      gap <= gap - 1;
    endrule

    rule rl_fill_slave (state == 6 && gap == 0 && idx < fromInteger(total));
      Bit#(8) b = idx < fromInteger(hd_tx) ? 8'hA0 + zeroExtend(idx)
                                           : tx_data[idx];
      let a <- slave.mav_write_req(`TX_data_rg, zeroExtend(b), sz_byte);
      $display($time, " slave  data_tx[%0d] <= %h  (%s) ok=%b", idx, b,
               idx < fromInteger(hd_tx) ? "filler" : "response", a);
      idx <= idx + 1;
      gap <= `TB_GAP;
    endrule

    rule rl_fill_slave_done (state == 6 && gap == 0 && idx >= fromInteger(total));
      state <= 7;
      idx   <= 0;
    endrule

    // --- 5: fill the MASTER TX FIFO with the command --------------------
    rule rl_fill_master_gap (state == 7 && gap != 0);
      gap <= gap - 1;
    endrule

    rule rl_fill_master (state == 7 && gap == 0 && idx < fromInteger(hd_tx));
      let a <- master.mav_write_req(`TX_data_rg,
                                    zeroExtend(tx_data[idx]), sz_byte);
      $display($time, " master data_tx[%0d] <= %h ok=%b", idx, tx_data[idx], a);
      idx <= idx + 1;
      gap <= `TB_GAP;
    endrule

    rule rl_fill_master_done (state == 7 && gap == 0 && idx >= fromInteger(hd_tx));
      state <= 8;
      idx   <= 0;
    endrule

    // --- 6: "AF" status --------------------------------------------------
    rule rl_status_af (state == 8);
      let sf <- slave.mav_read_req(`FIFO_status, sz_byte);
      let mf <- master.mav_read_req(`FIFO_status, sz_byte);
      $display($time, " AF fill : slave fifo=%h  master fifo=%h",
               tpl_2(sf)[7:0], tpl_2(mf)[7:0]);
      state <= 9;
    endrule

    // --- 7: slave length then comm_mode ---------------------------------
    rule rl_slave_len (state == 9);
      let a <- slave.mav_write_req(`Communication_control, slv_len, sz_word);
      $display($time, " slave  tx_rx_length(%0d,%0d): comm=%h ok=%b",
               slv_bits, slv_bits, slv_len, a);
      state <= 10;
    endrule

    rule rl_slave_mode (state == 10);
      let a <- slave.mav_write_req(`Communication_control, slv_mode, sz_word);
      $display($time, " slave  comm_mode(FULL_DUPLEX): comm=%h ok=%b", slv_mode, a);
      state <= 11;
    endrule

    // --- 8: master length then comm_mode --------------------------------
    rule rl_master_len (state == 11);
      let a <- master.mav_write_req(`Communication_control, mas_len, sz_word);
      $display($time, " master tx_rx_length(%0d,%0d): comm=%h ok=%b",
               tx_bits, rx_bits, mas_len, a);
      state <= 12;
    endrule

    rule rl_master_mode (state == 12);
      let a <- master.mav_write_req(`Communication_control, mas_mode, sz_word);
      $display($time, " master comm_mode(HALF_DUPLEX): comm=%h ok=%b", mas_mode, a);
      state <= 13;
    endrule

    // --- 9: enable the slave, then the master ---------------------------
    rule rl_slave_en (state == 13);
      let a <- slave.mav_write_req(`Communication_control, slv_en, sz_word);
      $display($time, " slave  enable_txrx(ENABLE) : comm=%h ok=%b", slv_en, a);
      state <= 14;
    endrule

    rule rl_master_en (state == 14);
      let a <- master.mav_write_req(`Communication_control, mas_en, sz_word);
      $display($time, " master enable_txrx(ENABLE) : comm=%h ok=%b", mas_en, a);
      state   <= 15;
      counter <= 0;
    endrule

    // --- 10: wait out both phases ---------------------------------------
    rule rl_wait (state == 15);
      if (counter >= wait_cycles) begin
        state   <= 16;
        counter <= 0;
      end
      else
        counter <= counter + 1;
    endrule

    // --- 11: master RXNE, then drain the response -----------------------
    rule rl_check_master_rxne (state == 16);
      let mc <- master.mav_read_req(`Communication_status, sz_byte);
      let mf <- master.mav_read_req(`FIFO_status, sz_byte);
      Bit#(8) cs = tpl_2(mc)[7:0];
      $display($time, " master comm_status=%h fifo_status=%h (RXNE=%b BUSY=%b)",
               cs, tpl_2(mf)[7:0], cs[2], cs[0]);
      // sspi.h: SPI_RXNE = (1<<2); the testcase gates the read on 0x4.
      if ((cs & 8'h04) != 0) begin
        state <= 17;
        idx   <= 0;
        gap   <= 0;
      end
      else begin
        $display(" Master did not receive any data ");
        $display("TEST FAILED");
        $finish();
      end
    endrule

    rule rl_drain_master_gap (state == 17 && gap != 0);
      gap <= gap - 1;
    endrule

    rule rl_drain_master (state == 17 && gap == 0 && idx < fromInteger(hd_rx));
      let r <- master.mav_read_req(`RX_data_rg, sz_byte);
      // Byte placement differs by bit order in mav_read_req: for MSB_FIRST a
      // size-0 read returns duplicate(rg_rx_data[31:24]), but for LSB_FIRST it
      // returns duplicate(rg_rx_data) whole, oldest byte in [7:0].
      Bit#(8) b = lsbfirst == 1 ? tpl_2(r)[7:0] : tpl_2(r)[31:24];
      mas_rx[idx] <= b;
      if (!tpl_1(r)) begin
        $display($time, " master data_rx[%0d] read FAILED (succ=0)", idx);
        nerr <= nerr + 1;
      end
      idx <= idx + 1;
      gap <= `TB_GAP;
    endrule

    rule rl_drain_master_done (state == 17 && gap == 0 && idx >= fromInteger(hd_rx));
      state <= 18;
      idx   <= 0;
      gap   <= 0;
    endrule

    // --- 12: slave RXNE, then drain the whole stream --------------------
    rule rl_check_slave_rxne (state == 18);
      let sc <- slave.mav_read_req(`Communication_status, sz_byte);
      let sf <- slave.mav_read_req(`FIFO_status, sz_byte);
      Bit#(8) cs = tpl_2(sc)[7:0];
      $display($time, " slave  comm_status=%h fifo_status=%h (RXNE=%b BUSY=%b)",
               cs, tpl_2(sf)[7:0], cs[2], cs[0]);
      if ((cs & 8'h04) != 0) begin
        state <= 19;
        idx   <= 0;
        gap   <= 0;
      end
      else begin
        $display(" Slave did not receive any data ");
        $display("TEST FAILED");
        $finish();
      end
    endrule

    rule rl_drain_slave_gap (state == 19 && gap != 0);
      gap <= gap - 1;
    endrule

    rule rl_drain_slave (state == 19 && gap == 0 && idx < fromInteger(total));
      let r <- slave.mav_read_req(`RX_data_rg, sz_byte);
      Bit#(8) b = lsbfirst == 1 ? tpl_2(r)[7:0] : tpl_2(r)[31:24];
      slv_rx[idx] <= b;
      if (!tpl_1(r)) begin
        $display($time, " slave data_rx[%0d] read FAILED (succ=0)", idx);
        nerr <= nerr + 1;
      end
      idx <= idx + 1;
      gap <= `TB_GAP;
    endrule

    rule rl_drain_slave_done (state == 19 && gap == 0 && idx >= fromInteger(total));
      state <= 20;
    endrule

    // --- 13: report ------------------------------------------------------
    rule rl_report (state == 20);
      Bit#(8) bad = 0;

      $display(" MASTER RECEIVED RESPONSE");
      for (Integer i = 0; i < valueOf(MaxBytes); i = i + 1)
        if (i < hd_rx) begin
          Bit#(8) exp = tx_data[hd_tx + i];
          Bit#(8) got = mas_rx[i];
          $display("   master rx[%0d]: %h   expected: %h   %s", i, got, exp,
                   got == exp ? "ok" : "MISMATCH");
          if (got != exp) bad = bad + 1;
        end

      $display(" SLAVE RECEIVED COMMAND");
      for (Integer i = 0; i < valueOf(MaxBytes); i = i + 1)
        if (i < hd_tx) begin
          Bit#(8) exp = tx_data[i];
          Bit#(8) got = slv_rx[i];
          $display("   slave  rx[%0d]: %h   expected: %h   %s", i, got, exp,
                   got == exp ? "ok" : "MISMATCH");
          if (got != exp) bad = bad + 1;
        end

      // Reported, not checked: the C testcase prints these without comparing.
      $display(" SLAVE TAIL (master's held MOSI during its receive phase)");
      for (Integer i = 0; i < valueOf(MaxBytes); i = i + 1)
        if (i >= hd_tx && i < total)
          $display("   slave  rx[%0d]: %h", i, slv_rx[i]);

      $display(" %0d of %0d checked bytes mismatched", bad, hd_rx + hd_tx);
      if (bad == 0 && nerr == 0)
        $display("TEST PASSED");
      else
        $display("TEST FAILED");
      $finish();
    endrule

  endmodule : mkTest
endpackage
