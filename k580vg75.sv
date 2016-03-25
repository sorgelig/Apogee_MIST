// ====================================================================
//                Radio-86RK FPGA REPLICA
//
//            Copyright (C) 2011 Dmitry Tselikov
//
// This core is distributed under modified BSD license. 
// For complete licensing information see LICENSE.TXT.
// -------------------------------------------------------------------- 
//
// An open implementation of K580WG75 CRT controller
//
// Author: Dmitry Tselikov   http://bashkiria-2m.narod.ru/
//
// Modifications: Sorgelig 
// 
// Design File: k580wg75.v
//
// Warning: This realization is not fully operational.

// altera message_off 10030

module k580vg75
(
	input        clk,
	input        clk_pix,

	input        iaddr,
	input  [7:0] idata,
	output [7:0] odata,
	input        iwe_n,
	input        ird_n,

	output reg   vrtc,
	output reg   hrtc,
	output       pix,

	input        dack,
	input  [7:0] ichar,
	input        symset,
	
	output reg   drq,
	output reg   irq,
	output [3:0] line,
	output       hilight,
	output [1:0] gattr
);

parameter CHAR_WIDTH = 5; // char width minus 1

reg[7:0] init0;
reg[7:0] init1;
reg[7:0] init2;
reg[7:0] init3;
reg[6:0] curx;
reg[5:0] cury;

wire[6:0] maxx = init0[6:0];
wire[6:0] maxy = {1'b0, init1[5:0]};
wire[3:0] underline  = init2[7:4];
wire[3:0] charheight = init2[3:0];
wire linemode = init3[7];
wire fillattr = init3[6]; // 0 - transparent, 1 - normal fill
wire curblink = init3[5]; // 0 - blink
wire curtype  = init3[4]; // 0 - block, 1 - underline

reg[7:0] ochar;
reg[3:0] chline;
reg[5:0] attr;
reg[5:0] attr2;
reg[6:0] ipos;
reg[7:0] opos;
reg[6:0] ypos;
reg[4:0] frame;
reg      lineff,err,vspfe;
reg      enable,inte,dmae;
reg[7:0] buf0[79:0];
reg[7:0] buf1[79:0];

wire vcur = opos=={1'b0,curx} && ypos==cury && (frame[3]|curblink);
wire[7:0] obuf = lineff ? buf0[opos] : buf1[opos];

assign odata = {1'b0,inte,irq,1'b0,err,enable,2'b0};
assign line = linemode==0 ? chline : chline==0 ? charheight : chline+4'b1111;
wire   lten = ((attr[5] || (curtype && vcur)) && chline==underline);
wire   vsp = (attr[1] && frame[4]) || (underline[3]==1'b1 && (chline==0||chline==charheight)) || !enable || ypos==0;
wire   rvv = attr[4] ^ (curtype==0 && vcur && chline<=underline);
assign gattr = attr2[3:2];
assign hilight = attr2[0];

reg [3:0] d_cnt;
reg [7:0] data;
wire[7:0] fdata;

reg hblank;
assign pix = (hrtc | hblank | vrtc) ? 1'b0 : data[CHAR_WIDTH];
wire clk_char = (!d_cnt & clk_pix);
always @(negedge clk_pix) begin
	if (d_cnt == CHAR_WIDTH) d_cnt <= 0;
		else d_cnt <= d_cnt+1'b1;
end

always @(posedge clk_pix) begin
	if (!d_cnt) begin 
		data <= vspfe ? 8'd0 : {8{rvv}} ^ (ochar[7] ? gdata : lten ? 8'hFF : (vsp ? 8'b0 : fdata));
		attr2 <= ochar[7] ? {attr[4:2], 1'b0, ochar[0]} : attr;
	end else data <= {data[6:0],1'b0};
end

wire [7:0] gdata = (ochar[1] && frame[4]) ? 8'd0 : gchar[{ochar[5:2], chline>underline, chline==underline}];

reg [7:0] gchar[64] = '{
		8'b00000000, 8'b00001111, 8'b00001000, 8'b00000000,
		8'b00000000, 8'b11111000, 8'b00001000, 8'b00000000,
		8'b00001000, 8'b00001111, 8'b00000000, 8'b00000000,
		8'b00001000, 8'b11111000, 8'b00000000, 8'b00000000,
		8'b00000000, 8'b11111111, 8'b00001000, 8'b00000000,
		8'b00001000, 8'b11111000, 8'b00001000, 8'b00000000,
		8'b00001000, 8'b00001111, 8'b00001000, 8'b00000000,
		8'b00001000, 8'b11111111, 8'b00000000, 8'b00000000,
		8'b00000000, 8'b11111111, 8'b00000000, 8'b00000000,
		8'b00001000, 8'b00001000, 8'b00001000, 8'b00000000,
		8'b00001000, 8'b11111111, 8'b00001000, 8'b00000000,
		8'b00000000, 8'b00000000, 8'b00000000, 8'b00000000,
		8'b00000000, 8'b00000000, 8'b00000000, 8'b00000000,
		8'b00000000, 8'b00000000, 8'b00000000, 8'b00000000,
		8'b00000000, 8'b00000000, 8'b00000000, 8'b00000000,
		8'b00000000, 8'b00000000, 8'b00000000, 8'b00000000
};

font from(.address({symset, ochar[6:0],line[2:0]}), .clock(clk_pix), .q(fdata));

reg  eos;
wire disp = ((ypos <= maxy) & ~eos);

always @(posedge clk) begin
	reg [5:0] exattr;
	reg [3:0] iposf;
	reg [3:0] oposf;
	reg [6:0] fifo0[15:0];
	reg [6:0] fifo1[15:0];
	reg [2:0] pstate;
	reg [9:0] l_cnt;
	reg [9:0] l_total;
	reg [9:0] h_cnt;
	reg [9:0] v_cnt;
	reg       exwe_n,exrd_n,exdack;
	reg       istate;

	exwe_n <= iwe_n; exrd_n <= ird_n;
	if(ird_n & ~exrd_n) begin
		irq <= 0;
		err <= 0;
	end
	if (~iwe_n & exwe_n) begin
		if (iaddr) begin
			case (idata[7:5])
				0: {enable,dmae,inte,pstate} <= 6'd1;
				1: {enable,inte} <= 2'b11;
				2: {enable,dmae} <= 0;
				3: pstate <= 5;
				4: pstate <= 5;
				5: inte   <= 1;
				6: inte   <= 0;
				7: ; // to do
			endcase
		end else begin
			case (pstate)
				1: {init0,pstate}    <= {idata,3'd2};
				2: {init1,pstate}    <= {idata,3'd3};
				3: {init2,pstate}    <= {idata,3'd4};
				4: {init3,pstate}    <= {idata,3'd0};
				5: {curx,pstate}     <= {idata[6:0]+1'b1,3'd6};
				6: {cury,pstate}     <= {idata[5:0]+1'b1,3'd0};
			  default: {err,pstate} <= {1'b1,3'd0};
			endcase
		end
	end

	exdack <= dack;
	if(!exdack & dack) begin
		if(istate) begin
			iposf  <= iposf + 1'b1;
			istate <= 0;
		end else begin 
			if(&{ichar[7:4], ichar[0]}) begin
				ipos <= 7'h7F;
				drq  <= 0;
				if(ichar[1]) dmae <= 0;
			end else begin
				ipos <= ipos + 1'b1;
				if(ipos >= maxx) drq <= 0;
			end
			istate <= (ichar[7:6]==2'b10) ? ~fillattr : 1'b0;
		end
		case({istate,lineff})
			2'b00: buf0[ipos]   <= ichar;
			2'b01: buf1[ipos]   <= ichar;
			2'b10: fifo0[iposf] <= ichar[6:0];
			2'b11: fifo1[iposf] <= ichar[6:0];
		endcase
	end

	if(clk_char) begin
		if(!h_cnt) begin
			if(!v_cnt) begin
				chline <= 0; ypos   <= 0;
				iposf  <= 0; ipos   <= 0;
				eos    <= 0; vspfe  <= 0;
				attr   <= 0; exattr <= 0; 
				l_cnt  <= 0;
				frame  <= frame + 1'b1;
				dmae   <= enable;
				drq    <= enable;
			end else begin
				if (chline==charheight) begin
					chline <= 0; iposf <= 0; ipos <= 0;
					lineff <= ~lineff;
					exattr <= attr;
					ypos   <= ypos + 1'b1;
					if(ypos==maxy) irq <= 1;
					if(!disp) vspfe <= 1;
					if(drq) {dmae,drq} <= 0; // DMA is't running. Try next frame.
					if((ypos < maxy) & dmae) drq <= 1;
				end else begin
					chline <= chline + 1'b1;
					attr   <= exattr;
				end

				if(disp && (l_cnt<308)) l_cnt <= l_cnt + 1'd1;
					else l_total <= l_cnt;
			end
			oposf <= 0;
			opos  <= 0;
		end else if (ypos!=0) begin

			if(~obuf[7:4]) opos <= opos + 1'b1;
				else if(obuf[1]) eos <= 1;

			if(opos > maxx) ochar <= 0;
			else begin
				if(obuf[7:6] == 2'b10) begin
					if (fillattr) begin
						ochar <= 0;
					end else begin
						ochar <= {1'b0, lineff ? fifo0[oposf] : fifo1[oposf]};
						oposf <= oposf + 1'b1;
					end
					attr <= obuf[5:0];
				end else begin
					ochar <= (~obuf[7:4]) ? obuf : 8'd0;
				end
			end
		end

		//fixed resolution 516x312(516x262) with real resolution centered inside
		if(h_cnt == 85) begin
			h_cnt <= 0;
			if((l_total > 20) && (l_total < 257) && !disp) begin
				if (v_cnt == 261) v_cnt <= 0;
					else v_cnt <= v_cnt+1'b1;

				if(v_cnt == (10'd131 + l_total[9:1])) vrtc <= 1;
				if(v_cnt == (10'd133 + l_total[9:1])) vrtc <= 0;
			end else begin
				if (v_cnt == 311) v_cnt <= 0;
					else v_cnt <= v_cnt+1'b1;

				if(v_cnt == (10'd154 + l_total[9:1])) vrtc <= 1;
				if(v_cnt == (10'd156 + l_total[9:1])) vrtc <= 0;
			end
		end else begin
			h_cnt <= h_cnt+1'b1;
		end

		if(h_cnt == 80) hblank <= 1;
		if(h_cnt == 3)  hblank <= 0;

		if(h_cnt == 80) hrtc <= 1;
		if(h_cnt == 85) hrtc <= 0;
	end
end

endmodule
