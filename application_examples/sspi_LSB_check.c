/***************************************************************************
 * Project               	    	    :  shakti devt board
  * Name of the file	            	:  sspi_LSB_check.c
 * Brief Description of file            :  sspi LSB check example code.
 * Name of Author    	                :  Kotteeswaran
 * Email ID                             :  kottee.1@gmail.com

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
/*Connection Details:
In FPGA Board check the Pinmux pins for SPI1 and short the MOSI and MISO pins of SPI1 according to board schematics.
*/
#include "platform.h"
#include "plic_driver.h"
#include "log.h"
#include "pinmux.h"
#include "sspi.h"
#ifdef BSOC
#include "uartv3.h"
#else
#include "uart.h"
#endif

#define SSPI_SIZE 8
#define DATA_SIZE 8
#define SSPI_INSTANCE 1

uint8_t spi1_tx[SSPI_SIZE] = {0};
uint8_t spi1_rx[SSPI_SIZE] = {0};


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
 * @param[Out] No output parameter
 */
void sspi_configure(sspi_struct *sspi_instance, uint32_t clk_rate, uint8_t clk_pol, uint8_t clk_phase, uint8_t pins_master, uint8_t mas_slv, uint8_t lsb_first, uint8_t setup_time, uint8_t hold_time)
{
	sspi_enable_txrx(sspi_instance, DISABLE);
	sspi_configure_clock(sspi_instance, clk_rate, clk_pol, clk_phase);
	sspi_configure_clock_in_hz(sspi_instance, clk_rate); /* Currently configuring for 100kHz, as the maximum clock is 20MHz */
	sspi_configure_clock_pol(sspi_instance, clk_pol);
	sspi_configure_clock_phase(sspi_instance, clk_phase);
	if (pins_master)
		sspi_configure_pins(sspi_instance, 1, 0, 1, 1);
	else
		sspi_configure_pins(sspi_instance, 0, 1, 0, 0);
	if (mas_slv)
		sspi_configure_mas_slv(sspi_instance, SPI_MASTER);
	if (!lsb_first)
	{
		sspi_configure_lsb_first(sspi_instance, MSB_FIRST);
	}
	else
	{
		sspi_configure_lsb_first(sspi_instance, LSB_FIRST);
	}
	printf("\n SSPI 1 Commn CONTROL: %x", sspi_instance->comm_control);
	sspi_configure_tx_setup_time(sspi_instance, setup_time);
	sspi_configure_tx_hold_time(sspi_instance, hold_time);
}

/**
 * @brief Main function to test SSPI1 in LSB-first full-duplex communication mode.
 * @details function Initializes the SSPI module.Configures SSPI with clock, phase, polarity, setup/hold time, and MSB-first format.
 * Transmits a series of bytes via SSPI.Receives and verifies the transmitted data if available.This loop continuously fills TX FIFO with *incrementing values, waits for transfer completion,and prints received data( in LSB first format) from the RX FIFO.
 * @return Returns 0 on successful execution.
 */
int main()
{
	uint32_t temp = 0, retval = 0;
	uint8_t i = 0, j = 0;
	uint8_t temp_data = 0;
	uint32_t clk_rate = SSPI_CLOCK_FREQUENCY;
	uint8_t setup_time = SETUP_TIME_CYCLES, hold_time = HOLD_TIME_CYCLES;
	*(pinmux_config_reg) = 0x154000;
	printf("\n SSPI LSB Check\n");

	sspi_init();
	printf("\n SSPI 1 Commn status: %x", sspi_instance[SSPI_INSTANCE]->comm_status);
	printf("\n SSPI 1 Fifo status: %x", sspi_instance[SSPI_INSTANCE]->fifo_status);
	sspi_clear_fifo(sspi_instance[SSPI_INSTANCE]);
	printf("\n SSPI 1 Commn status: %x", sspi_instance[SSPI_INSTANCE]->comm_status);
	printf("\n SSPI 1 Fifo status: %x", sspi_instance[SSPI_INSTANCE]->fifo_status);
	temp = sspi_notbusy(sspi_instance[SSPI_INSTANCE]);
	printf("SSPI1 status: %x \n", temp);
	sspi_configure(sspi_instance[SSPI_INSTANCE], clk_rate, CLK_POLARITY_HIGH, CLK_PHASE_HIGH, MASTER, SPI_MASTER, LSB_FIRST, setup_time, hold_time);
	
	temp = sspi_notbusy(sspi_instance[SSPI_INSTANCE]);
	printf("SSPI1 status: %x \n", temp);
	delay_loop(2000, 1000);
	while (1)
	{
		temp_data = 0x01;
		for (i = 0; i < SSPI_SIZE; i++)
		{
			spi1_rx[i] = 0;
			spi1_tx[i] = temp_data;
			temp_data += 0x01;
		}
		printf("\n Filling Fifo data");
		for (i = 0; i < SSPI_SIZE; i++)
		{
			sspi_instance[SSPI_INSTANCE]->data_tx = spi1_tx[i];
		}
		sspi_configure_tx_rx_length(sspi_instance[SSPI_INSTANCE], SSPI_SIZE * DATA_SIZE, SSPI_SIZE * DATA_SIZE);
		sspi_configure_comm_mode(sspi_instance[SSPI_INSTANCE], FULL_DUPLEX);
		sspi_enable_txrx(sspi_instance[SSPI_INSTANCE], ENABLE);
		temp = sspi_notbusy(sspi_instance[SSPI_INSTANCE]);
		// printf("\n SSPI 1 Commn status: %x", sspi_instance[SSPI_INSTANCE]->comm_status );
		// printf("\n SSPI 1 Fifo status: %x", sspi_instance[SSPI_INSTANCE]->fifo_status );
		if (((0x4 & sspi_instance[SSPI_INSTANCE]->comm_status)) != 0)
		{
			// printf("\n SSPI 1 Commn status: %x", sspi_instance[SSPI_INSTANCE]->comm_status );
			// printf("\n SSPI 1 Fifo status: %x", sspi_instance[SSPI_INSTANCE]->fifo_status );
			for (int i = 0; i < SSPI_SIZE; i++)
			{
				spi1_rx[i] = sspi_instance[SSPI_INSTANCE]->data_rx;
			}
			printf("\n SSPI READ VALUES");
			for (int i = 0; i < SSPI_SIZE; i++)
			{
				printf("\n SSPI1[%x]: %x", i, spi1_rx[i]);
			}
		}
		else
		{
			printf("\n Didn't receive any data ");
		}
		delay_loop(2000, 1000);
	}
	return 0;
}
