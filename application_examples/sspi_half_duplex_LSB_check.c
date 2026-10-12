/***************************************************************************
 * Project               	    	    :  shakti devt board
 * Name of the file	            	    :  sspi_half_duplex_LSB_check.c
 * Brief Description of file            :  sspi half duplex (LSB first) example code.
 * Name of Author    	                :  Aashrith Narayn
 * Email ID                             :  aashnarayn22@gmail.com

 Copyright (C) 2025  IIT Madras. All rights reserved.

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.
***************************************************************************/

/*Half duplex notes:
HALF_DUPLEX (SPICOMMMODE = 2'b10) is "transmit, then immediately receive" within a
single chip select assertion: the master clocks out SSPI_TX_SIZE bytes on MOSI and then
clocks in SSPI_RX_SIZE bytes on MISO before releasing CS. It is a two party command /
response transaction, so the response has to be driven by the slave instance.

The controller has no "receive then transmit" mode, so the slave cannot be a mirror of
the master. Instead the slave runs FULL_DUPLEX across the whole transaction, with its
transmit and receive lengths both set to the master's transmit plus receive length. The
slave therefore shifts continuously, and the alignment works out as:

  master transmit phase (bits 1..32)  : slave receives the command into its RX bytes 0..3
                                        slave transmits its TX bytes 0..3, which the
                                        *master ignores* (its receiver is still IDLE)
  master receive phase  (bits 33..64) : master captures the slave's TX bytes 4..7
                                        slave keeps sampling MOSI, which now holds the
                                        master's last transmitted bit

Note:
  - The master's rx_length must be non zero. With comm_mode 2 the setup delay counter in
    rl_set_up_time is gated on rg_total_bit_rx != 0, so rx_length 0 wedges the
    transaction before it starts.
*/
#include "platform.h"
#include "plic_driver.h"
#include "log.h"
#include "sspi.h"
#include "uart.h"

#define SIM 1
// #define SSPI_DEBUG 1
// #define SSPI_INTERRUPT_BASE PLIC_INTERRUPT_3

/* Clock polarity and phase for this testcase - substitute manually with
   CLK_POLARITY_HIGH / CLK_POLARITY_LOW and CLK_PHASE_HIGH / CLK_PHASE_LOW from sspi.h */
#define SSPI_CLK_POL CLK_POLARITY_HIGH
#define SSPI_CLK_PHA CLK_PHASE_HIGH

#define SSPI_MASTER_INSTANCE 0
#define SSPI_SLAVE_INSTANCE 1
#define DATA_SIZE 8
#define SSPI_TX_SIZE 4 /* Bytes the master clocks out during the transmit phase */
#define SSPI_RX_SIZE 4 /* Bytes the master clocks in  during the receive  phase */
#define SSPI_SLAVE_SIZE (SSPI_TX_SIZE + SSPI_RX_SIZE) /* Slave shifts across both phases */

#define SSPI_SLAVE_FILLER_DATA 0xA0 /* Slave bytes clocked out while the master is transmitting */

uint8_t spi0_tx[SSPI_TX_SIZE] 	 = {0};          /* Master command bytes */
uint8_t spi0_rx[SSPI_RX_SIZE] 	 = {0};          /* Master received response bytes */
uint8_t spi1_tx[SSPI_SLAVE_SIZE] = {0};       /* Slave stream: filler, then the response */
uint8_t spi1_rx[SSPI_SLAVE_SIZE] = {0};       /* Slave captures the command, then idle MOSI */

uint8_t slave_response[SSPI_RX_SIZE] = {0x5a, 0x6b, 0x7c, 0x8d};  /* We explicitly provide this data to the slave for the master to recieve after transmitting its own data*/

/** @fn sspi_configure(sspi_struct *sspi_instance, uint32_t clk_rate, uint8_t clk_pol, uint8_t clk_phase, uint8_t pins_master, uint8_t mas_slv, uint8_t lsb_first, uint8_t setup_time, uint8_t hold_time) 
 * @brief sspi configuration function which configures the SSPI registers
 * @details Configures the SSPI registers like control register, clock register, etc. 
 * @warning No warning
 * @param[in] sspi_struct *sspi_instance ---> instance of SSPI that needs to be configured
 * 			  clk_rate --> SSPI clock frequency.
 * 			  clk_pol --> Polarity of the clock
 * 			  clk_phase --> Phase of the clock, 
 * 			  pins_master --> SPI pin functionality (master or slave)
 * 			  mas_slv --> SSPI Master / SSPI Slave, 
 * 			  lsb_first --> Bit transfer (MSB first / LSB first),
 *  		  setup_time --> Delay in data transfer after CS is low and before the data transmit starts,
 * 			  hold_time ---> Delay after data transfer completes and before CS becomes high.
 * @param[out] None
 */
void sspi_configure(sspi_struct *sspi_instance, uint32_t clk_rate, uint8_t clk_pol, uint8_t clk_phase, uint8_t pins_master, uint8_t mas_slv, uint8_t lsb_first, uint8_t setup_time, uint8_t hold_time)
{
 	sspi_enable_txrx(sspi_instance, DISABLE);
	sspi_configure_clock(sspi_instance, clk_rate, clk_pol, clk_phase);
	sspi_configure_clock_in_hz(sspi_instance, clk_rate); /* Currently configuring for 1MHz, as the maximum clock is 20MHz */
	sspi_configure_clock_pol(sspi_instance, clk_pol);
	sspi_configure_clock_phase(sspi_instance, clk_phase);	
	if(pins_master)
		sspi_configure_pins(sspi_instance, 1, 0 ,  1 , 1);
	else
		sspi_configure_pins(sspi_instance, 0, 1 ,  0 , 0);
	if(mas_slv)
		sspi_configure_mas_slv(sspi_instance, SPI_MASTER);
	else
		sspi_configure_mas_slv(sspi_instance, ~SPI_MASTER);
	if(!lsb_first)
	{
		sspi_configure_lsb_first(sspi_instance, MSB_FIRST);
	}
	else
	{
		sspi_configure_lsb_first(sspi_instance, LSB_FIRST);
	}
	sspi_configure_tx_setup_time(sspi_instance, setup_time);
	sspi_configure_tx_hold_time(sspi_instance, hold_time);
}

/**
 * @brief Main function to test SSPI half duplex communication in LSB-first format.
 * @details This function initialises both SSPI instances and configures SSPI0 as the
 * LSB-first master and SSPI1 as the LSB-first slave responder. Each iteration preloads
 * the slave's TX FIFO with filler bytes followed by the response pattern, preloads the
 * master's TX FIFO with the command bytes, programs the master's transmit and receive
 * bit lengths separately for HALF_DUPLEX and the slave's lengths to span both phases,
 * then starts the slave before the master. Once both instances report not busy, the
 * master's received bytes are compared against the slave's response and the slave's
 * received bytes against the master's command.
 * @note Requires two instances of the SSPI controller cross wired to each other.
 *		 MOSI1 <-> MOSI2, MISO1 <-> MISO2, SCLK1<-> SCLK2, NCS1 <-> NCS2
 * @return int Always returns 0. Runs indefinitely for repeated checks.
 */
int main()
{
	unsigned long hartid;
	asm volatile ("csrr %0, mhartid" : "=r"(hartid));
	uint32_t temp = 0;
	uint8_t i = 0;
	uint8_t temp_data = 0;
	uint8_t fail_count = 0;
	uint32_t clk_rate = SSPI_CLOCK_FREQUENCY;
	uint8_t setup_time = SETUP_TIME_CYCLES, hold_time = HOLD_TIME_CYCLES;
	uint32_t comm_ctrl = 0;
	uint8_t tx_bits = 0, last_byte = 0, m = 0, shift = 0, idle = 0;

	sspi_init();
	#ifndef SIM
	new_printf(hartid,"SSPI Half Duplex LSB Check: SSPI0 master, SSPI1 slave\n");
	#endif
	sspi_clear_fifo(sspi_instance[SSPI_MASTER_INSTANCE],hartid);
	sspi_clear_fifo(sspi_instance[SSPI_SLAVE_INSTANCE],hartid);
	temp = sspi_notbusy(sspi_instance[SSPI_MASTER_INSTANCE],hartid);
	temp = sspi_notbusy(sspi_instance[SSPI_SLAVE_INSTANCE],hartid);
	sspi_configure(sspi_instance[SSPI_SLAVE_INSTANCE], clk_rate, SSPI_CLK_POL, SSPI_CLK_PHA, SLAVE, SLAVE, LSB_FIRST, 0, hold_time);
	sspi_configure(sspi_instance[SSPI_MASTER_INSTANCE], clk_rate, SSPI_CLK_POL, SSPI_CLK_PHA, MASTER, SPI_MASTER, LSB_FIRST, setup_time, hold_time);
	temp = sspi_notbusy(sspi_instance[SSPI_SLAVE_INSTANCE],hartid);
	temp = sspi_notbusy(sspi_instance[SSPI_MASTER_INSTANCE],hartid);
	#ifdef SIM
	delay_loop(20, 10);
	#else 
	delay_loop(200, 100);
	#endif
	while (1)
	{
		temp_data = 0x01;
		for (i = 0; i < SSPI_TX_SIZE; i++)
		{
			spi0_tx[i] = temp_data;
			temp_data += 0x02;
		}
		for (i = 0; i < SSPI_TX_SIZE; i++)
		{
			spi1_tx[i] = SSPI_SLAVE_FILLER_DATA + i;
		}
		for (i = 0; i < SSPI_RX_SIZE; i++)
		{
			spi1_tx[SSPI_TX_SIZE + i] = slave_response[i];
		}
		new_printf(hartid,"Filling Fifo data\n");

		#ifdef SSPI_DEBUG
		new_printf(hartid,"BF SSPI0 Commn status: %x\n", sspi_instance[SSPI_MASTER_INSTANCE]->comm_status);
		new_printf(hartid,"BF SSPI0 Fifo status: %x\n", sspi_instance[SSPI_MASTER_INSTANCE]->fifo_status);
		new_printf(hartid,"BF SSPI1 Commn status: %x\n", sspi_instance[SSPI_SLAVE_INSTANCE]->comm_status);
		new_printf(hartid,"BF SSPI1 Fifo status: %x\n", sspi_instance[SSPI_SLAVE_INSTANCE]->fifo_status);
		#endif
		for (i = 0; i < SSPI_SLAVE_SIZE; i++)
		{
			sspi_instance[SSPI_SLAVE_INSTANCE]->data_tx = spi1_tx[i];
		}
		for (i = 0; i < SSPI_TX_SIZE; i++)
		{
			sspi_instance[SSPI_MASTER_INSTANCE]->data_tx = spi0_tx[i];
		}
		#ifdef SSPI_DEBUG		
		new_printf(hartid,"AF SSPI0 Commn status: %x\n", sspi_instance[SSPI_MASTER_INSTANCE]->comm_status);
		new_printf(hartid,"AF SSPI0 Fifo status: %x\n", sspi_instance[SSPI_MASTER_INSTANCE]->fifo_status);
		new_printf(hartid,"AF SSPI1 Commn status: %x\n", sspi_instance[SSPI_SLAVE_INSTANCE]->comm_status);
		new_printf(hartid,"AF SSPI1 Fifo status: %x\n", sspi_instance[SSPI_SLAVE_INSTANCE]->fifo_status);
		#endif

		sspi_configure_tx_rx_length(sspi_instance[SSPI_SLAVE_INSTANCE], SSPI_SLAVE_SIZE * DATA_SIZE, SSPI_SLAVE_SIZE * DATA_SIZE);
		sspi_configure_comm_mode(sspi_instance[SSPI_SLAVE_INSTANCE], FULL_DUPLEX);
		sspi_configure_tx_rx_length(sspi_instance[SSPI_MASTER_INSTANCE], SSPI_TX_SIZE * DATA_SIZE, SSPI_RX_SIZE * DATA_SIZE);
		sspi_configure_comm_mode(sspi_instance[SSPI_MASTER_INSTANCE], HALF_DUPLEX);
		/* Slave must be enabled before the master drives CS low */
		sspi_enable_txrx(sspi_instance[SSPI_SLAVE_INSTANCE], ENABLE);
		sspi_enable_txrx(sspi_instance[SSPI_MASTER_INSTANCE], ENABLE);
		/* Returns only after the transmit phase AND the receive phase are complete */
		temp = sspi_notbusy(sspi_instance[SSPI_MASTER_INSTANCE],hartid);
		#ifdef SSPI_DEBUG 
		new_printf(hartid,"Master not busy\n");
		#endif
		temp = sspi_notbusy(sspi_instance[SSPI_SLAVE_INSTANCE],hartid);
		#ifdef SSPI_DEBUG 
		new_printf(hartid,"Slave not busy\n");
		#endif

		/* Derive the byte the slave sees while the master holds MOSI during its receive phase. 
		   That bit is then held for the whole receive window, so the received byte is the same bit replicated eight times. */
		comm_ctrl = sspi_instance[SSPI_MASTER_INSTANCE]->comm_control;
		tx_bits   = (comm_ctrl & SPI_TOTAL_BITS_TX(0xFF)) >> 6;
		last_byte = spi0_tx[(tx_bits - 1) / 8];
		m         = (tx_bits % 8) ? (tx_bits % 8) : 8;
		shift     = (comm_ctrl & SPI_LSB_FIRST) ? (m - 1) : (8 - m);
		idle      = (uint8_t)(0u - ((last_byte >> shift) & 0x01));

		fail_count = 0;
		if (((0x4 & sspi_instance[SSPI_MASTER_INSTANCE]->comm_status)) != 0)
		{
			for (i = 0; i < SSPI_RX_SIZE; i++)
			{
				spi0_rx[i] = sspi_instance[SSPI_MASTER_INSTANCE]->data_rx;
			}
			new_printf(hartid,"MASTER RECEIVED RESPONSE\n");
			for (i = 0; i < SSPI_RX_SIZE; i++)
			{
				new_printf(hartid,"SSPI0[%x]: %x expected: %x\n", i, spi0_rx[i], slave_response[i]);
				if (spi0_rx[i] != slave_response[i])
					fail_count += 1;
			}
		}
		else
		{
			new_printf(hartid,"Master did not receive any data\n");
			fail_count += 1;
		}

		if (((0x4 & sspi_instance[SSPI_SLAVE_INSTANCE]->comm_status)) != 0)
		{
			for (i = 0; i < SSPI_SLAVE_SIZE; i++)
			{
				spi1_rx[i] = sspi_instance[SSPI_SLAVE_INSTANCE]->data_rx;
			}
			new_printf(hartid,"SLAVE RECEIVED DATA\n");
			for (i = 0; i < SSPI_TX_SIZE; i++)
			{
				new_printf(hartid,"SSPI1[%x]: %x expected: %x\n", i, spi1_rx[i], spi0_tx[i]);
				if (spi1_rx[i] != spi0_tx[i])
					fail_count += 1;
			}
			/* Tail bytes are the master's held MOSI bit during its receive phase */
			new_printf(hartid,"SLAVE TAIL (idle MOSI, expected %x)\n", idle);
			for (i = SSPI_TX_SIZE; i < SSPI_SLAVE_SIZE; i++)
			{
				new_printf(hartid,"SSPI1[%x]: %x\n", i, spi1_rx[i]);
			}
		}
		else
		{
			new_printf(hartid,"Slave did not receive any data\n");
			fail_count += 1;
		}

		if (fail_count == 0)
			new_printf(hartid,"Half duplex LSB check passed\n");
		else
			new_printf(hartid,"Half duplex LSB check failed, %x mismatches\n", fail_count);
		#ifdef SIM 
		delay_loop(200, 100);
		#else 
		delay_loop(2000, 1000);
		#endif
	}
	return 0;
}
