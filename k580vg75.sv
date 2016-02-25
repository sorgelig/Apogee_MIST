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
reg enable,inte,dmae;
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
reg[5:0] exattr;
reg[3:0] iposf;
reg[3:0] oposf;
reg[6:0] ipos;
reg[7:0] opos;
reg[6:0] ypos;
reg[4:0] frame;
reg lineff,exwe_n,exrd_n,err,vspfe;
reg[6:0] fifo0[15:0];
reg[6:0] fifo1[15:0];
reg[7:0] buf0[79:0];
reg[7:0] buf1[79:0];
reg[2:0] pstate;
reg[9:0] l_cnt;
reg[9:0] l_total;
reg istate;

wire vcur = opos=={1'b0,curx} && ypos==cury && (frame[3]|curblink);
wire[7:0] obuf = lineff ? buf0[opos] : buf1[opos];

assign odata = {1'b0,inte,irq,1'b0,err,enable,2'b0};
assign line = linemode==0 ? chline : chline==0 ? charheight : chline+4'b1111;
wire   lten = ((attr[5] || (curtype && vcur)) && chline==underline);
wire   vsp = (attr[1] && frame[4]) || (underline[3]==1'b1 && (chline==0||chline==charheight)) || !enable || vspfe || ypos==0;
wire   rvv = attr[4] ^ (curtype==0 && vcur && chline<=underline);
assign gattr = attr2[3:2];
assign hilight = attr2[0];

reg[3:0] d_cnt;
reg[7:0] data;
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
		data <= ypos>(maxy+1'd1) ? 8'd0 : ochar[7] ? gdata : lten ? 8'hFF : {8{rvv}} ^ (vsp ? 8'b0 : fdata);
		attr2 <= ochar[7] ? ochar[0] : attr;
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

wire hrst = !h_cnt;
wire vrst = (((10'd310 - l_total)>>1) == v_cnt) & hrst;

reg[9:0] h_cnt;
reg[9:0] v_cnt;

always @(posedge clk) begin
	exwe_n <= iwe_n; exrd_n <= ird_n;
	if (ird_n & ~exrd_n) begin
		irq <= 0; err <= 0;
	end
	if (iwe_n & ~exwe_n) begin
		if (iaddr) begin
			case (idata[7:5])
			3'b000: {enable,inte,pstate} <= 5'b00001;
			3'b001: {enable,inte} <= 2'b11;
			3'b010: enable <= 0;
			3'b011: pstate <= 3'b101;
			3'b100: pstate <= 3'b101;
			3'b101: inte <= 1'b1;
			3'b110: inte <= 1'b0;
			3'b111: enable <= 0; // to do
			endcase
		end else begin
			case (pstate)
			3'b001: {init0,pstate} <= {idata,3'b010};
			3'b010: {init1,pstate} <= {idata,3'b011};
			3'b011: {init2,pstate} <= {idata,3'b100};
			3'b100: begin {init3,pstate} <= {idata,3'b000}; l_total <= 0; end
			3'b101: {curx,pstate} <= {idata[6:0]+1'b1,3'b110};
			3'b110: {cury,pstate} <= {idata[5:0]+1'b1,3'b000};
			default: {err,pstate} <= 4'b1000;
			endcase
		end
	end
	if (clk_char) begin
		if (vrst) begin
			l_cnt <= 0;
			chline <= 0; ypos <= 0; dmae <= 1'b1; vspfe <= 0;
			iposf <= 0; ipos <= 0; oposf <= 0; opos <= 0;
			attr <= 0; exattr <= 0; frame <= frame + 1'b1;
		end else
		if (hrst) begin
			if (chline==charheight) begin
				chline <= 0; lineff <= ~lineff;
				exattr <= attr; iposf <= 0; ipos <= 0;
				ypos <= ypos + 1'b1;
				if (ypos==maxy) irq <= 1'b1;
			end else begin
				chline <= chline + 1'b1;
				attr <= exattr;
			end

			if(vrtc || (ypos == (maxy+1'b1))) l_total <= l_cnt;
				else if(ypos <= maxy) l_cnt <= l_cnt + 1'd1;

			oposf <= 0; opos <= {2'b0,maxx[6:1]}+8'hD0;
		end else if (ypos!=0) begin
			if (obuf[7:2]==6'b111100) begin
				if (obuf[1]) vspfe <= 1'b1;
			end else
				opos <= opos + 1'b1;
			if (opos > maxx)
				ochar <= 0;
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
					ochar <= obuf;
				end
			end
		end
		if (dack && drq) begin
			drq <= 0;
			case (istate)
				1'b0: begin
					if (ichar[7:4]==4'b1111 && ichar[0]==1'b1) begin
						ipos <= 7'h7F;
						if (ichar[1]==1'b1) dmae <= 0;
					end else begin
						ipos <= ipos + 1'b1;
					end
					istate <= ichar[7:6]==2'b10 ? ~fillattr : 1'b0;
				end
				1'b1: begin
					iposf <= iposf + 1'b1;
					istate <= 0;
				end
			endcase
			case ({istate,lineff})
				2'b00: buf0[ipos] <= ichar;
				2'b01: buf1[ipos] <= ichar;
				2'b10: fifo0[iposf] <= ichar[6:0];
				2'b11: fifo1[iposf] <= ichar[6:0];
			endcase
		end else begin
			drq <= ipos > maxx || ypos > maxy ? 1'b0 : dmae&enable;
		end
		
		//fixed resolution 534x312 with real resolution centered inside
		if (h_cnt == 88) begin
			h_cnt <= 0;
			if (v_cnt == 311) begin 
				v_cnt <= 0;
				vrtc  <= 0;
			end else begin 
				v_cnt <= v_cnt+1'b1;
				if(v_cnt == 309) vrtc <= 1;
			end
		end else begin
			h_cnt <= h_cnt+1'b1;
		end

		if(h_cnt == 2)  hblank <= 1;
		if(h_cnt == 12) hblank <= 0;

		if(h_cnt == 2) hrtc <= 1;
		if(h_cnt == 8) hrtc <= 0;
	end
end

endmodule
