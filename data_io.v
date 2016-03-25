//
// data_io.v
//
// io controller writable ram for the MiST board
// http://code.google.com/p/mist-board/
//
// ZX Spectrum adapted version
//
// Copyright (c) 2015 Till Harbaum <till@harbaum.org>
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

module data_io 
(
	// io controller spi interface
	input         sck,
	input         ss,
	input         sdi,

	input   [1:0] reset,
	output        downloading,   // signal indicating an active download
   output reg [4:0]  index,     // menu index used to upload the file
	 
	// external ram interface
	input         clk,
	output reg    wr = 0,
	output [24:0] a,
	output [7:0]  d
);

assign downloading = downloading_reg || erasing;
assign d = erasing ? 8'h00      : data;
assign a = erasing ? erase_addr : write_a;

reg [6:0]  sbuf;
reg [7:0]  cmd;
reg [7:0]  data;
reg [4:0]  cnt;

reg [24:0] addr;
reg [24:0] waddr;
reg [24:0] write_a = 25'h200000;
reg [24:0] erase_addr = 0;
reg        rclk = 1'b0;
reg        erase_trigger;
reg        erasing = 0;
reg [24:0] erase_mask;

localparam UIO_FILE_TX      = 8'h53;
localparam UIO_FILE_TX_DAT  = 8'h54;
localparam UIO_FILE_INDEX   = 8'h55;

reg downloading_reg = 1'b0;
reg [15:0] start_addr;
reg  [4:0] new_index;

always@(posedge reset[0], posedge downloading_reg) begin
	if(downloading_reg) index <= new_index;
		else index <= {reset[1],1'b0};
end

// data_io has its own SPI interface to the io controller
always@(posedge sck, posedge ss) begin
	if(ss == 1'b1)
		cnt <= 5'd0;
	else begin
		rclk <= 1'b0;
		erase_trigger <= 1'b0;

		// don't shift in last bit. It is evaluated directly
		// when writing to ram
		if(cnt != 15) sbuf <= { sbuf[5:0], sdi};

		// increase target address after write
		if(rclk) begin
			addr <= addr + 25'd1;
			if(addr == 25'h100003) addr <= start_addr;
		end

		// count 0-7 8-15 8-15 ... 
		if(cnt < 15) cnt <= cnt + 4'd1;
			else cnt <= 4'd8;

		// finished command byte
      if(cnt == 7)
			cmd <= {sbuf, sdi};

		// prepare/end transmission
		if((cmd == UIO_FILE_TX) && (cnt == 15)) begin
			// prepare 
			if(sdi) begin
				case(new_index)
					      0: addr <= 25'h200000; // ROMDISK
					    1,2: addr <= 25'h100000; // RKA, RKR
					default: addr <= 25'h0FFFFF; // GAM, skip sync byte
				endcase
				downloading_reg <= 1'b1; 
			end else begin
				downloading_reg <= 1'b0; 
				if(new_index) begin
					waddr <= addr;
					erase_trigger <= 1;
				end
			end
		end

		// command 0x54: UIO_FILE_TX
		if((cmd == UIO_FILE_TX_DAT) && (cnt == 15)) begin
			if(addr == 25'h100000) begin
				start_addr[15:8] <= {sbuf, sdi};
				data <= 8'hC3;
				write_a <= 0;
			end else if(addr == 25'h100001) begin
				data <= {sbuf, sdi};
				start_addr[7:0] <= {sbuf, sdi};
				write_a <= 1;
			end else if(addr == 25'h100002) begin
				data <= start_addr[15:8];
				write_a <= 2;
			end else begin
				write_a <= addr;
				data <= {sbuf, sdi};
			end
			rclk <= 1'b1;
		end
		
      // expose file (menu) index
      if((cmd == UIO_FILE_INDEX) && (cnt == 15))
			new_index <= {sbuf[3:0], sdi};
	end
end

wire [24:0] next_addr = (erase_addr + 25'd1) & erase_mask;

always@(posedge clk) begin
	reg rclkD, rclkD2;
	reg eraseD, eraseD2;
	reg  [4:0] erase_clk_div;
	reg [24:0] end_addr;
	rclkD <= rclk;
	rclkD2 <= rclkD;
	wr <= 0;
	
	if(rclkD && !rclkD2) wr <= 1;

	eraseD <= erase_trigger;
	eraseD2 <= eraseD;

	// start erasing
	if(eraseD && !eraseD2) begin
		erase_clk_div <= 0;
		erase_addr <= waddr;
		erase_mask <= 25'hFFFF;
		end_addr <= start_addr;
		erasing <= 1;
	end else begin
		erase_clk_div <= erase_clk_div + 5'd1;
		if(!erase_clk_div) begin
			if(next_addr != end_addr) begin
				erase_addr <= next_addr;
				if(next_addr > 2) wr <= 1;
			end else begin
				erasing <= 0;
			end
		end
	end
end 

endmodule
