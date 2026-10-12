/***************************************************************************
 * Project               	    	    :  shakti devt board
 * Name of the file	            	    :  sspi__simplex_tx.c
 * Brief Description of file            :  sspi simplex tx mode test code.
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
#include  "pinmux.h"
#include "sspi.h"

#include "uart.h"


#define SSPI_SIZE 8
#define DATA_SIZE 8
#define SSPI_DRIVER 1
#define SSPIX_INSTANCE 2//master
#define SSPIY_INSTANCE 3//slave

uint8_t spi2_tx[SSPI_SIZE] = {0};
uint8_t spi2_rx[SSPI_SIZE] = {0};
uint8_t spi3_tx[SSPI_SIZE] = {0};
uint8_t spi3_rx[SSPI_SIZE] = {0};

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
	if(pins_master)
		sspi_configure_pins(sspi_instance, 1, 0 ,  1 , 1);
	else
		sspi_configure_pins(sspi_instance, 0, 1 ,  0 , 0);
	if(mas_slv)
		sspi_configure_mas_slv(sspi_instance, SPI_MASTER);
	else//added by sugnathi
		sspi_configure_mas_slv(sspi_instance, ~SPI_MASTER);
	if(!lsb_first)
		sspi_configure_lsb_first(sspi_instance, MSB_FIRST);
	sspi_configure_tx_setup_time(sspi_instance, setup_time);
	sspi_configure_tx_hold_time(sspi_instance, hold_time);
}

/**
 * @fn int main()
 * @brief Entry point for the SSPI simplex communication test
 * @details this function Initializes UART and enables SSPI clocks,Configures pinmux settings for SPI communication
 * Clears SSPI FIFOs and waits for idle state,Configures one SSPI as Master Transmitter (SIMPLEX_TX) and the other as Slave
 * Receiver  (SIMPLEX_RX)Populates TX buffer with sequential data and writes it into the TX FIFOStarts transmission and receives data into 
 * RX buffer Compares and prints received data Runs continuously in a loop for repeated testing
 * @warning This test assumes proper hardware loopback between SPI master and slave pins.
 * @return int Always returns 0
 */

int main()
{
	uint32_t temp = 0, retval = 0;
	uint8_t i = 0, j = 0;
	uint8_t temp_data = 0;
	uint32_t clk_rate = SSPI_CLOCK_FREQUENCY;
	// uint8_t setup_time = 0;
	uint8_t setup_time = SETUP_TIME_CYCLES;
	uint8_t hold_time = HOLD_TIME_CYCLES;

	*(pinmux_config_reg) = 0x154000;
	sspi_init();
	printf("\n SSPI 2 Commn status: %x", sspi_instance[SSPIX_INSTANCE]->comm_status);
	printf("\n SSPI 2 Fifo status: %x", sspi_instance[SSPIX_INSTANCE]->fifo_status);
	printf("\n SSPI 3 Commn status: %x", sspi_instance[SSPIY_INSTANCE]->comm_status);
	printf("\n SSPI 3 Fifo status: %x", sspi_instance[SSPIY_INSTANCE]->fifo_status);
	sspi_clear_fifo(sspi_instance[SSPIX_INSTANCE]);
	sspi_clear_fifo(sspi_instance[SSPIY_INSTANCE]);
	temp = sspi_notbusy(sspi_instance[SSPIY_INSTANCE]);
	printf("\n SSPI3 status: %x", temp);
	temp = sspi_notbusy(sspi_instance[SSPIX_INSTANCE]);
	printf("\n SSPI2 status: %x", temp);
	sspi_configure(sspi_instance[SSPIY_INSTANCE], clk_rate, CLK_POLARITY_LOW, CLK_PHASE_LOW, SLAVE, SLAVE, MSB_FIRST, setup_time, hold_time);
	sspi_configure(sspi_instance[SSPIX_INSTANCE], clk_rate, CLK_POLARITY_LOW, CLK_PHASE_LOW, MASTER, SPI_MASTER, MSB_FIRST, setup_time, hold_time);

	temp = sspi_notbusy(sspi_instance[SSPIY_INSTANCE]);
	temp = sspi_notbusy(sspi_instance[SSPIX_INSTANCE]);
	delay_loop(2000, 1000);
	while (1)
	{
		// temp_data = 0xAA;
		temp_data = 0x01;
		for (i = 0; i < SSPI_SIZE; i++)
		{
			spi2_rx[i] = 0;
			// if (i == 7) temp_data = 0x55;
			// spi2_tx[i] = temp_data;
			spi2_tx[i] = temp_data + i;
		}
		printf("\n Filling Fifo data");
		printf("\n BF SSPI 3 Commn status: %x", sspi_instance[SSPIY_INSTANCE]->comm_status);
		printf("\n SSPI 3 Fifo status: %x", sspi_instance[SSPIY_INSTANCE]->fifo_status);
		printf("\n SSPI 2 Commn status: %x", sspi_instance[SSPIX_INSTANCE]->comm_status);
		printf("\n SSPI 2 Fifo status: %x", sspi_instance[SSPIX_INSTANCE]->fifo_status);
		for (i = 0; i < SSPI_SIZE; i++)
		{
			sspi_instance[SSPIX_INSTANCE]->data_tx = spi2_tx[i];
		}
		printf("\n AF SSPI 3 Commn status: %x", sspi_instance[SSPIY_INSTANCE]->comm_status);
		printf("\n SSPI 3 Fifo status: %x", sspi_instance[SSPIY_INSTANCE]->fifo_status);
		printf("\n SSPI 2 Commn status: %x", sspi_instance[SSPIX_INSTANCE]->comm_status);
		printf("\n SSPI 2 Fifo status: %x", sspi_instance[SSPIX_INSTANCE]->fifo_status);
		sspi_configure_tx_rx_length(sspi_instance[SSPIY_INSTANCE], 0, SSPI_SIZE * DATA_SIZE);
		sspi_configure_comm_mode(sspi_instance[SSPIY_INSTANCE], SIMPLEX_RX);
		sspi_enable_txrx(sspi_instance[SSPIY_INSTANCE], ENABLE);

		sspi_configure_tx_rx_length(sspi_instance[SSPIX_INSTANCE], SSPI_SIZE * DATA_SIZE, 0);
		sspi_configure_comm_mode(sspi_instance[SSPIX_INSTANCE], SIMPLEX_TX);
		sspi_enable_txrx(sspi_instance[SSPIX_INSTANCE], ENABLE);
		printf("\n Config Done");
		temp = sspi_notbusy(sspi_instance[SSPIX_INSTANCE]);
		printf("\n Master not busy");
		temp = sspi_notbusy(sspi_instance[SSPIY_INSTANCE]);
		printf("\n Slave not busy");
		// printf("\n SSPI 0 Commn status: %x", sspi_instance[SSPIY_INSTANCE]->comm_status );
		// printf("\n SSPI 0 Fifo status: %x", sspi_instance[SSPIY_INSTANCE]->fifo_status );
		// printf("\n SSPI 1 Commn status: %x", sspi_instance[SSPIX_INSTANCE]->comm_status );
		// printf("\n SSPI 1 Fifo status: %x", sspi_instance[SSPIX_INSTANCE]->fifo_status );

		if (((0x4 & sspi_instance[SSPIY_INSTANCE]->comm_status)) != 0)
		{
			// printf("\n SSPI 0 Commn status: %x", sspi_instance[SSPIY_INSTANCE]->comm_status );
			// printf("\n SSPI 0 Fifo status: %x", sspi_instance[SSPIY_INSTANCE]->fifo_status );
			// printf("\n SSPI 1 Commn status: %x", sspi_instance[SSPIX_INSTANCE]->comm_status );
			// printf("\n SSPI 1 Fifo status: %x", sspi_instance[SSPIX_INSTANCE]->fifo_status );
			for (int i = 0; i < SSPI_SIZE; i++)
			{
				printf("\n i=%d", i);
				spi3_rx[i] = sspi_instance[SSPIY_INSTANCE]->data_rx;
			}
			printf("\n SSPI READ VALUES");
			for (int i = 0; i < SSPI_SIZE; i++)
			{
				printf("\nSSPI3[%x]: %x", i, spi3_rx[i]);
			}
		}
		else
		{
			printf("\n Didn't receive any data ");
		}
		delay_loop(20000, 10000);
	}
	return 0;
}
