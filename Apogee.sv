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

wire [7:0] status;
wire [1:0] buttons;
wire scandoubler_disable;
wire ps2_kbd_clk, ps2_kbd_data;

user_io #(.STRLEN(85)) user_io 
(
	.conf_str(     "APOGEE;RKA;F2,RKR;F3,GAM;O1,Color,On,Off;O4,Turbo,Off,On;O5,Autostart,Yes,No;T6,Reset"),
	.SPI_SCK(SPI_SCK),
	.CONF_DATA0(CONF_DATA0),
	.SPI_DO(SPI_DO),
	.SPI_DI(SPI_DI),

	.status(status),
	.buttons(buttons),
	.scandoubler_disable(scandoubler_disable),

	.ps2_clk(clk_ps2),
	.ps2_kbd_clk(ps2_kbd_clk),
	.ps2_kbd_data(ps2_kbd_data)
);

wire mode86 = (ioctl_index>1);

////////////////////   CLOCKS   ///////////////////
wire locked;
pll pll
(
	.inclk0(CLOCK_27[0]),
	.locked(locked),
	.c0(clk_ram),
	.c1(SDRAM_CLK),
	.c2(clk_sys)
);

wire clk_sys;       // 50Mhz
wire clk_ram;       // 100MHz
reg  clk_io;        // 25MHz
                    //
                    // strobes:
reg  clk_f1,clk_f2; // 1.78MHz/3.5MHz
reg  clk_pix;       // 8MHz
reg  clk_pix2x;     // 16MHz
reg  clk_pit;       // 1.78MHz
reg  clk_dma;       // 1.78MHz
reg  clk_ps2;       // 14KHz

always @(negedge clk_sys) begin
	reg [2:0] clk_viddiv;
	reg [5:0] cpu_div = 0;
	int ps2_div;
	reg turbo = 0;

	clk_io <= ~clk_io;

	clk_viddiv <= clk_viddiv + 1'd1;
	if(clk_viddiv == 5) clk_viddiv <=0;
	clk_pix   <= !clk_viddiv;
	clk_pix2x <= !clk_viddiv || (clk_viddiv == 3);

	cpu_div <= cpu_div + 1'd1;
	if(cpu_div == 27) begin 
		cpu_div <= 0;
		turbo <= status[4];
	end
	clk_f1 <= ((cpu_div == 0) | (turbo & (cpu_div == 14)));
	clk_f2 <= ((cpu_div == 2) | (turbo & (cpu_div == 16)));

	clk_pit <= (cpu_div == 4);
	clk_dma <= (cpu_div == 4);
	
	ps2_div <= ps2_div+1;
	if(ps2_div == 3570) ps2_div <=0;
	clk_ps2 <= !ps2_div;

	startup <= reset|(startup&~addrbus[15]);
end

////////////////////   RESET   ////////////////////
reg [3:0] reset_cnt;
reg       reset = 1;

wire    RESET = status[0] | status[6] | buttons[1] | reset_key[0];
integer initRESET = 20000000;

always @(posedge clk_sys) begin
	if ((!RESET && reset_cnt==4'd14) && !initRESET && !ioctl_download)
		reset <= 0;
	else begin
		if(initRESET && !ioctl_download) initRESET <= initRESET - 1;
		reset <= 1;
		reset_cnt <= reset_cnt+4'd1;
	end
end

////////////////////   MEM   ////////////////////
wire[7:0] ram_o;
sram sram
( 
	.*,
	.init(!locked),
	.clk_sdram(clk_ram),
	.dout(ram_o),
	.din( ioctl_download ? ioctl_data : cpu_o),
	.addr(ioctl_download ? ioctl_addr : hlda ? vid_addr     : addr),
	.we(  ioctl_download ? ioctl_wr   : hlda ? 1'b0         : !cpu_wr_n && !ppa2_a_acc),
	.rd(  ioctl_download ? 1'b0       : hlda ? !dma_oiord_n : cpu_rd)
);

wire ppa2_a_acc = ((addrbus[15:8] == 8'hEE) && (addrbus[1:0] == 2'd0));
wire [24:0] addr = (ppa2_a_acc & !mode86) ? {3'b100, extaddr} : addrbus;

wire [7:0] rom_o;
bios   rom(.address({addrbus[11]|startup,addrbus[10:0]}), .clock(clk_sys), .q(rom_o));

wire [7:0] rom86_o;
bios86 rom86(.address(addrbus[10:0]), .clock(clk_sys), .q(rom86_o));

////////////////////   CPU   ////////////////////
wire [15:0] addrbus;
reg   [7:0] cpu_i;
wire  [7:0] cpu_o;
wire        cpu_sync;
wire        cpu_rd;
wire        cpu_wr_n;
wire        cpu_int;
wire        cpu_inta_n;
wire        inte;
reg         startup;

always_comb begin
	casex({startup, mode86, addrbus[15:8]})
		10'h0EC: cpu_i <= pit_o;
		10'h0ED: cpu_i <= ppa1_o;
		10'h0EE: cpu_i <= (addrbus[1] | addrbus[0]) ? ppa2_o : ram_o;
		10'h0EF: cpu_i <= crt_o;
		10'h0FX: cpu_i <= rom_o;
		10'h2XX: cpu_i <= rom_o;
		10'b01100XXXXX: cpu_i <= ppa1_o;
		10'b0110100XXX: cpu_i <= pit_o;
		10'b0110101XXX: cpu_i <= 0; // sd_o
		10'b011011XXXX: cpu_i <= 0; // ???
		10'b01110XXXXX: cpu_i <= crt_o;
		10'b01111XXXXX: cpu_i <= rom86_o;
		10'b11XXXXXXXX: cpu_i <= rom86_o;
		default: cpu_i <= ram_o;
	endcase
end

wire pit_we_n  = mode86 ? addrbus[15:11]!=5'b10100|cpu_wr_n : addrbus[15:8]!=8'hEC|cpu_wr_n;
wire pit_rd    = mode86 ? addrbus[15:11]==5'b10100&cpu_rd   : addrbus[15:8]==8'hEC&cpu_rd;
wire ppa1_we_n = mode86 ? addrbus[15:13]!=3'b100|cpu_wr_n   : addrbus[15:8]!=8'hED|cpu_wr_n;
wire ppa2_we_n = mode86 ? 1'b1                              : addrbus[15:8]!=8'hEE|cpu_wr_n;
wire crt_we_n  = mode86 ? addrbus[15:13]!=3'b110|cpu_wr_n   : addrbus[15:8]!=8'hEF|cpu_wr_n;
wire crt_rd_n  = mode86 ? addrbus[15:13]!=3'b110|~cpu_rd    : addrbus[15:8]!=8'hEF|~cpu_rd;
wire dma_we_n  = mode86 ? addrbus[15:13]!=3'b111|cpu_wr_n   : addrbus[15:8]!=8'hF0|cpu_wr_n;

k580vm80a cpu
(
   .pin_clk(clk_sys),
   .pin_f1(clk_f1),
   .pin_f2(clk_f2),
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
wire  [7:0] crt_o;
wire  [3:0] vid_line;
wire [15:0] vid_addr;
wire  [3:0] dma_dack;
wire  [7:0] dma_o;
wire  [1:0] vid_gattr;
wire vid_drq,vid_irq,hlda;
wire vid_hilight;
wire dma_owe_n,dma_ord_n,dma_oiowe_n,dma_oiord_n;
wire hrq;

k580vt57 dma
(
	.clk(clk_sys), 
	.ce(clk_dma), 
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
	.symset(mode86 ? 1'b0 : inte)
);

wire pix;
wire [5:0] bw_pix = {{2{pix}}, {4{pix & vid_hilight}}};

wire hsync, vsync;

osd osd 
(
	.*,
	.VGA_Rx(status[1] ? bw_pix : {6{pix & ~vid_hilight }}),
	.VGA_Gx(status[1] ? bw_pix : {6{pix & ~vid_gattr[1]}}),
	.VGA_Bx(status[1] ? bw_pix : {6{pix & ~vid_gattr[0]}}),
	.VGA_R(VGA_Rs),
	.VGA_G(VGA_Gs),
	.VGA_B(VGA_Bs),
	.OSD_HS(hsync),
	.OSD_VS(vsync)
);

wire [5:0] VGA_Rs;
wire [5:0] VGA_Gs;
wire [5:0] VGA_Bs;

scandoubler scandoubler 
(
	.clk_x2(clk_pix2x),

	.scanlines(0),
		    
	.hs_in(hsync),
	.vs_in(vsync),
	.r_in(VGA_Rs),
	.g_in(VGA_Gs),
	.b_in(VGA_Bs),

	.hs_out(hsyncd),
	.vs_out(vsyncd),
	.r_out(VGA_Rd),
	.g_out(VGA_Gd),
	.b_out(VGA_Bd)
);

wire hsyncd, vsyncd;
wire [5:0] VGA_Rd;
wire [5:0] VGA_Gd;
wire [5:0] VGA_Bd;

assign VGA_HS = scandoubler_disable ? ~(hsync ^ vsync) : ~hsyncd;
assign VGA_VS = scandoubler_disable ? 1'b1 : ~vsyncd;
assign VGA_R  = scandoubler_disable ? VGA_Rs : VGA_Rd;
assign VGA_G  = scandoubler_disable ? VGA_Gs : VGA_Gd;
assign VGA_B  = scandoubler_disable ? VGA_Bs : VGA_Bd;

////////////////////   KBD   ////////////////////
wire [7:0] kbd_o;
wire [2:0] kbd_shift;
wire [2:0] reset_key;

rk_kbd kbd
(
	.clk(clk_sys), 
	.reset(reset),
	.downloading(ioctl_download && (ioctl_index != 0) && !status[5]),
	.ps2_clk(ps2_kbd_clk),
	.ps2_dat(ps2_kbd_data),
	.addr(~ppa1_a), 
	.odata(kbd_o), 
	.shift(kbd_shift),
	.reset_key(reset_key)
);

////////////////////   SYS PPA   ////////////////////
wire [7:0] ppa1_o;
wire [7:0] ppa1_a;
wire [7:0] ppa1_b;
wire [7:0] ppa1_c;

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

wire [7:0] ppa2_o;
wire [7:0] ppa2_a;
wire [7:0] ppa2_b;
wire [7:0] ppa2_c;

reg [3:0] tm9;
always @(posedge ppa2_c[7]) tm9<=ppa2_b[3:0];
wire [18:0] extaddr = {tm9, ppa2_c[6:0], ppa2_b};

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
wire tapein = 1'b0;

wire[7:0] pit_o;
wire pit_out0;
wire pit_out1;
wire pit_out2;

pit8253 pit
(
	.clk(clk_sys),
	.tce(clk_pit),
	.a(addrbus[1:0]),
	.wr(~pit_we_n),
	.rd(pit_rd),
	.din(cpu_o),
	.dout(pit_o),
	.gate(3'b111),
	.out({pit_out2, pit_out1, pit_out0}),
	.tpsel(0)
);

assign AUDIO_R = AUDIO_L;
sigma_delta_dac #(.MSBI(2)) dac
(
	.CLK(clk_sys),
	.RESET(reset),
	.DACin(2'd0 + ppa1_c[0] + (mode86 & inte) + pit_out0 + pit_out1 + pit_out2),
	.DACout(AUDIO_L)
);

//////////////////   EXTROM   //////////////////
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_data;
wire [24:0] ioctl_size;
wire        ioctl_download;
wire  [4:0] ioctl_index;

data_io data_io(
	.sck(SPI_SCK),
	.ss(SPI_SS2),
	.sdi(SPI_DI),

	.downloading(ioctl_download),
	.size(ioctl_size),
	.index(ioctl_index),
	.reset({reset_key[2], reset}),

	.clk(clk_io),
	.wr(ioctl_wr),
	.a(ioctl_addr),
	.d(ioctl_data)
);

assign LED = ~ioctl_download;

endmodule
