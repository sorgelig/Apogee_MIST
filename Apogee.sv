// ====================================================================
//                Apogee BK-01 FPGA REPLICA
//
//            Copyright (C) 2016 Sorgelig
//
// This core is distributed under modified BSD license. 
// For complete licensing information see LICENSE.TXT.
// -------------------------------------------------------------------- 
//
// An open implementation of Apogee BK-01 home computer
//
// Based on code from Dmitry Tselikov
// 

`define WITH_LEDs

module Apogee
(
   input  wire [1:0]  CLOCK_27,            // Input clock 27 MHz

   output wire [5:0]  VGA_R,
   output wire [5:0]  VGA_G,
   output wire [5:0]  VGA_B,
   output wire        VGA_HS,
   output wire        VGA_VS,
	 
   output wire        LED,

   output wire        AUDIO_L,
   output wire        AUDIO_R,

   input  wire        SPI_SCK,
   output wire        SPI_DO,
   input  wire        SPI_DI,
   input  wire        SPI_SS2,
   input  wire        SPI_SS3,
   input  wire        SPI_SS4,
   input  wire        CONF_DATA0,

   output wire [12:0] SDRAM_A,
   inout  wire [15:0] SDRAM_DQ,
   output wire        SDRAM_DQML,
   output wire        SDRAM_DQMH,
   output wire        SDRAM_nWE,
   output wire        SDRAM_nCAS,
   output wire        SDRAM_nRAS,
   output wire        SDRAM_nCS,
   output wire [1:0]  SDRAM_BA,
   output wire        SDRAM_CLK,
   output wire        SDRAM_CKE
);

assign LED = 1;

wire clk_sys;
wire clk_ram;
wire clk_ps2;
wire locked;
pll pll(.locked(locked), .inclk0(CLOCK_27[0]), .c0(clk_ram), .c1(SDRAM_CLK), .c2(clk_sys), .c3(clk_ps2));

wire [7:0] status;
wire [1:0] buttons;

wire RESET = status[0] | status[2] | buttons[1];

wire ps2_kbd_clk, ps2_kbd_data;

user_io #(.STRLEN(86)) user_io (
	.conf_str("RADIO86;;T2,Reset"),
	.SPI_SCK(SPI_SCK),
	.CONF_DATA0(CONF_DATA0),
	.SPI_DO(SPI_DO),
	.SPI_DI(SPI_DI),
	
	.status(status),
	.buttons(buttons),
	
	.ps2_clk(clk_ps2),
	.ps2_kbd_clk(ps2_kbd_clk),
	.ps2_kbd_data(ps2_kbd_data)
);

////////////////////   RESET   ////////////////////
reg[3:0] reset_cnt;
reg reset_n;
wire reset = ~reset_n;

always @(posedge clk_sys) begin
	if (!RESET && reset_cnt==4'd14)
		reset_n <= 1'b1;
	else begin
		reset_n <= 1'b0;
		reset_cnt <= reset_cnt+4'd1;
	end
end

////////////////////   MEM   ////////////////////

wire[7:0] ram_o;
sram sram( .*,
    .init(!locked),
	 .clk_sdram(clk_ram),
	 .dout(ram_o),
	 .din(cpu_o),
	 .addr(hlda ? vid_addr[15:0] : addrbus[15:0]),
	 .we(hlda ? 1'b0 : !cpu_wr_n),
	 .rd(hlda ? !dma_oiord_n : cpu_rd)
);

wire[7:0] rom_o;
bios rom(.address({addrbus[11]|startup,addrbus[10:0]}), .clock(clk_sys), .q(rom_o));

////////////////////   CPU   ////////////////////
wire[15:0] addrbus;
wire[7:0] cpu_o;
wire cpu_sync;
wire cpu_rd;
wire cpu_wr_n;
wire cpu_int;
wire cpu_inta_n;
wire inte;
reg startup;

wire [7:0] cpu_i = (addrbus < 16'hEC00) ? (startup ? rom_o : ram_o) :
               (addrbus[15:8] == 8'hEC) ? pit_o  :
               (addrbus[15:8] == 8'hED) ? ppa1_o :
               (addrbus[15:8] == 8'hEE) ? ppa2_o :
               (addrbus[15:8] == 8'hEF) ? crt_o  :
                                          rom_o;

wire pit_we_n  = addrbus[15:8]!=8'hEC|cpu_wr_n;
wire pit_rd  = ~(addrbus[15:8]!=8'hEC|~cpu_rd);
wire ppa1_we_n = addrbus[15:8]!=8'hED|cpu_wr_n;
wire ppa2_we_n = addrbus[15:8]!=8'hEE|cpu_wr_n;
wire crt_we_n  = addrbus[15:8]!=8'hEF|cpu_wr_n;
wire crt_rd_n  = addrbus[15:8]!=8'hEF|~cpu_rd;
wire dma_we_n  = addrbus[15:8]!=8'hF0|cpu_wr_n;

reg f1,f2;
reg clk_pix;
always @(negedge clk_sys) begin
	reg [2:0] clk_viddiv;
	reg [5:0] cpu_div = 0;

	clk_viddiv <= clk_viddiv + 1'd1;
	clk_pix <=0;
	if(clk_viddiv == 5) begin
		clk_viddiv <=0;
		clk_pix <=1;
	end
	
	cpu_div <= cpu_div + 1'd1;
	if(cpu_div == 26) cpu_div <= 0;
	f1 <= (cpu_div == 0);
	f2 <= (cpu_div == 2);

	startup <= reset|(startup&~addrbus[15]);
end

k580vm80a cpu
(
   .pin_clk(clk_sys),
	.pin_f1(f1),
   .pin_f2(f2),
   .pin_reset(reset),
   .pin_a(addrbus),
   .pin_dout(cpu_o),
   .pin_din(cpu_i),
   .pin_hold(hrq),
   .pin_hlda(hlda),
   .pin_ready(1),
   .pin_wait(),
   .pin_int(cpu_int),
   .pin_inte(inte),
   .pin_sync(cpu_sync),
   .pin_dbin(cpu_rd),
   .pin_wr_n(cpu_wr_n)
);


////////////////////   VIDEO   ////////////////////
wire[7:0] crt_o;
wire[3:0] vid_line;
wire[15:0] vid_addr;
wire[3:0] dma_dack;
wire[7:0] dma_o;
wire[1:0] vid_gattr;
wire clk_char,vid_drq,vid_irq,hlda;
wire vid_hilight;
wire dma_owe_n,dma_ord_n,dma_oiowe_n,dma_oiord_n;

wire hsync, vsync;
wire hrq;

k580vt57 dma
(
	.clk(clk_sys), 
	.ce(f2), 
	.reset(reset),
	.iaddr(addrbus[3:0]), 
	.idata(cpu_o), 
	.drq({1'b0,vid_drq,2'b00}), 
	.iwe_n(dma_we_n), 
	.ird_n(1'b1),
	.hlda(hlda), 
	.hrq(hrq), 
	.dack(dma_dack), 
	.odata(dma_o), 
	.oaddr(vid_addr),
	.owe_n(dma_owe_n), 
	.ord_n(dma_ord_n), 
	.oiowe_n(dma_oiowe_n), 
	.oiord_n(dma_oiord_n) 
);

k580vg75 crt
(
	.clk(clk_sys), 
	.clk_pix(clk_pix), 
	.clk_char(clk_char),
	.iaddr(addrbus[0]), 
	.idata(cpu_o), 
	.iwe_n(crt_we_n), 
	.ird_n(crt_rd_n),
	.vrtc(vsync), 
	.hrtc(hsync), 
	.pix(pix),
	.dack(dma_dack[2]), 
	.ichar(ram_o), 
	.drq(vid_drq), 
	.irq(vid_irq),
	.odata(crt_o), 
	.line(vid_line), 
	.hilight(vid_hilight), 
	.gattr(vid_gattr),
	.symset(inte)
);

wire pix;
assign VGA_R = {pix,pix,pix,pix,pix,pix};
assign VGA_G = {pix,pix,pix,pix,pix,pix};
assign VGA_B = {pix,pix,pix,pix,pix,pix};
assign VGA_HS = ~(hsync ^ vsync);
assign VGA_VS = 1;

////////////////////   KBD   ////////////////////
wire[7:0] kbd_o;
wire[2:0] kbd_shift;

rk_kbd kbd
(
	.clk(clk_sys), 
	.reset(reset), 
	.ps2_clk(ps2_kbd_clk), 
	.ps2_dat(ps2_kbd_data),
	.addr(~ppa1_a), 
	.odata(kbd_o), 
	.shift(kbd_shift)
);

////////////////////   SYS PPA   ////////////////////
wire[7:0] ppa1_o;
wire[7:0] ppa1_a;
wire[7:0] ppa1_b;
wire[7:0] ppa1_c;

k580vv55 ppa1
(
	.clk(clk_sys), 
	.reset(reset), 
	.addr(addrbus[1:0]), 
	.we_n(ppa1_we_n),
	.idata(cpu_o), 
	.odata(ppa1_o), 
	.ipa(ppa1_a), 
	.opa(ppa1_a),
	.ipb(~kbd_o), 
	.opb(ppa1_b), 
	.ipc({~kbd_shift,tapein,ppa1_c[3:0]}), 
	.opc(ppa1_c)
);

wire[7:0] ppa2_o;
wire[7:0] ppa2_a;
wire[7:0] ppa2_b;
wire[7:0] ppa2_c;

k580vv55 ppa2
(
	.clk(clk_sys), 
	.reset(reset), 
	.addr(addrbus[1:0]), 
	.we_n(ppa2_we_n),
	.idata(cpu_o), 
	.odata(ppa2_o), 
	.ipa(ppa2_a), 
	.opa(ppa2_a),
	.ipb(ppa2_b), 
	.opb(ppa2_b), 
	.ipc(ppa2_c), 
	.opc(ppa2_c)
);


////////////////////   SOUND   ////////////////////

assign AUDIO_R = AUDIO_L;
wire tapein = 1'b0;

wire[7:0] pit_o;
wire pit_out0;
wire pit_out1;
wire pit_out2;

k580vi53 pit
(
	.clk(clk_sys), 
	.c0(f2), 
	.c1(f2), 
	.c2(f2),
	.g0(1), 
	.g1(1), 
	.g2(1), 
	.out0(pit_out0), 
	.out1(pit_out1), 
	.out2(pit_out2),
	.addr(addrbus[1:0]), 
	.rd(pit_rd), 
	.we_n(pit_we_n), 
	.idata(cpu_o), 
	.odata(pit_o)
);

sigma_delta_dac #(.MSBI(3)) dac_l (
	.CLK(f2),
	.RESET(reset),
	.DACin(3'd0 + ppa1_c[0] + pit_out0 + pit_out1 + pit_out2),
	.DACout(AUDIO_L)
);


endmodule
