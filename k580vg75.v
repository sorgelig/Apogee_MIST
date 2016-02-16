// ====================================================================
//                Radio-86RK FPGA REPLICA
//
//            Copyright (C) 2011 Dmitry Tselikov
//
// This core is distributed under modified BSD license. 
// For complete licensing information see LICENSE.TXT.
// -------------------------------------------------------------------- 
//
// An open implementation of K580VG75 CRT controller
//
// Author: Dmitry Tselikov   http://bashkiria-2m.narod.ru/
// 
// Design File: k580vg75.v
//
// Warning: This realization is not fully operational.

module k580vg75
(
	input        clk,
	input        clk_pix,
	output       clk_char,

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
	output       lten,
	output       vsp,
	output       rvv,
	output       hilight,
	output [1:0] gattr
);

parameter CHAR_WIDTH = 5;

reg[7:0] init0; //SHHHHHHH
reg[7:0] init1; //VVRRRRRR 
reg[7:0] init2; //UUUULLLL 
reg[7:0] init3; //MFCCZZZZ
reg enable,inte,dmae;
reg[2:0] dmadelay;
reg[1:0] dmalen;
reg[6:0] curx;
reg[5:0] cury;

wire[6:0] maxx = init0[6:0];
wire[5:0] maxy = init1[5:0];
wire[3:0] underline  = init2[7:4];
wire[3:0] charheight = init2[3:0];
wire linemode = init3[7];
wire fillattr = init3[6]; // 0 - transparent, 1 - normal fill
wire curblink = init3[5]; // 0 - blink
wire curtype  = init3[4]; // 0 - block, 1 - underline
wire [6:0] hrsz = {1'b0, init3[3:0], 1'b1};
wire [5:0] vrsz = {4'd0, init1[7:6]};

reg[6:0] ochar;

reg[3:0] chline;
reg[5:0] attr;
reg[5:0] exattr;
reg[3:0] iposf;
reg[3:0] oposf;
reg[6:0] ipos;
reg[7:0] opos;
reg[5:0] ypos;
reg[4:0] frame;
reg lineff,exwe_n,exrd_n,exvrtc,exhrtc,err,vspfe;
reg[6:0] fifo0[15:0];
reg[6:0] fifo1[15:0];
reg[7:0] buf0[79:0];
reg[7:0] buf1[79:0];
reg[2:0] pstate;
reg istate;

wire vcur = opos=={1'b0,curx} && ypos==cury && (frame[3]|curblink);
wire[7:0] obuf = lineff ? buf0[opos] : buf1[opos];

assign odata = {1'b0,inte,irq,1'b0,err,enable,2'b0};
assign line = linemode==0 ? chline : chline==0 ? charheight : chline+4'b1111;
assign lten = ((attr[5] || (curtype && vcur)) && chline==underline);
assign vsp = (attr[1] && frame[4]) || (underline[3]==1'b1 && (chline==0||chline==charheight)) || !enable || vspfe || ypos==0;
assign rvv = attr[4] ^ (curtype==0 && vcur && chline<=underline);
assign gattr = attr[3:2];
assign hilight = attr[0];

reg irq_set = 0;
reg irq_clear = 0;
always @(posedge irq_clear or posedge irq_set) begin
	if(irq_set) irq <= 1;
		else irq <= 0;
end

always @(posedge clk) begin
	irq_clear <= 0;
	exwe_n <= iwe_n; exrd_n <= ird_n;
	if (ird_n & ~exrd_n) begin
		irq_clear <= 1; err <= 0;
	end
	if (iwe_n & ~exwe_n) begin
		if (iaddr) begin //CREG
			case (idata[7:5])
				0: {enable,inte,pstate} <= 5'b00001;  // reset
				1: {enable,inte,dmadelay,dmalen} <= {2'b11,idata[4:0]}; // start
				2: enable <= 0; // stop
				3: pstate <= 5; // read pen
				4: pstate <= 5; // set cur xy
				5: inte   <= 1; // enable int
				6: inte   <= 0; // disable int
				7: enable <= 0; // to do
			endcase
		end else begin //PREG
			case (pstate)
				1: {init0,pstate} <= {idata,3'd2};
				2: {init1,pstate} <= {idata,3'd3};
				3: {init2,pstate} <= {idata,3'd4};
				4: {init3,pstate} <= {idata,3'd0};
				5: {curx,pstate}  <= {idata[6:0]+1'b1,3'd6};
				6: {cury,pstate}  <= {idata[5:0]+1'b1,3'd0};
			default: {err,pstate}<= 4'b1000;
			endcase
		end
	end
end

reg[3:0] d_cnt;
reg[5:0] data;
wire[7:0] fdata;

assign pix = data[5];
assign clk_char = (!d_cnt & clk_pix);
always @(negedge clk_pix) begin
	if (d_cnt == CHAR_WIDTH) d_cnt <= 0;
		else d_cnt <= d_cnt+1'b1;
end

always @(posedge clk_pix) begin
	if (!d_cnt) data <= lten ? 6'h3F : vsp ? 6'b0 : fdata[5:0]^{6{rvv}};
		else data <= {data[4:0],1'b0};
end

font from(.address({symset, ochar[6:0],line[2:0]}), .clock(clk_pix), .q(fdata));

reg [6:0] h_cnt;
reg [6:0] v_cnt;
reg [3:0] v_str;

always @(posedge clk_char) begin
	irq_set <= 0;
	if (h_cnt == maxx) begin
		hrtc <= 1;
		if (chline==charheight) begin
			chline <= 0; lineff <= ~lineff;
			exattr <= attr; iposf <= 0; ipos <= 0;
			ypos <= ypos + 1'b1;
			if (ypos==maxy) irq_set <= 1'b1;
		end else begin
			chline <= chline + 1'b1;
			attr <= exattr;
		end
		oposf <= 0; opos <= {2'b0,maxx[6:1]}+8'hD0;
	end else if (ypos!=0) begin
		if (obuf[7:2]==6'b111100) begin
			if (obuf[1]) vspfe <= 1'b1;
		end else
			opos <= opos + 1'b1;
		if (opos > maxx)
			ochar <= 0;
		else begin
			casex (obuf[7:6])
			2'b0x: ochar <= obuf[6:0];
			2'b10: begin
				if (fillattr) begin
					ochar <= 0;
				end else begin
					ochar <= lineff ? fifo0[oposf] : fifo1[oposf];
					oposf <= oposf + 1'b1;
				end
				attr <= obuf[5:0];
			end
			2'b11: ochar <= 0;
			endcase
		end
	end
	
	if (dack && drq) begin
		drq <= 0;
		if(!istate) begin
				if (ichar[7:4]==4'b1111 && ichar[0]==1'b1) begin
				ipos <= 7'h7F;
				if (ichar[1]==1'b1) dmae <= 0;
			end else begin
				ipos <= ipos + 1'b1;
			end
			istate <= ichar[7:6]==2'b10 ? ~fillattr : 1'b0;
		end else begin
			iposf <= iposf + 1'b1;
			istate <= 0;
		end
		case ({istate,lineff})
			2'b00: buf0[ipos] <= ichar;
			2'b01: buf1[ipos] <= ichar;
			2'b10: fifo0[iposf] <= ichar[6:0];
			2'b11: fifo1[iposf] <= ichar[6:0];
		endcase
	end else begin
		drq <= ipos > maxx || ypos > maxy ? 1'b0 : dmae&enable;
	end

	if (h_cnt >= (maxx+hrsz+7'd1)) begin
		h_cnt <= 0;
		hrtc <= 0;
		if (v_str==charheight) begin
			v_str <= 0;
			if (v_cnt == maxy) begin 
				vrtc <= 1;
				chline <= 0; ypos <= 0; dmae <= 1'b1; vspfe <= 0;
				iposf <= 0; ipos <= 0; oposf <= 0; opos <= 0;
				attr <= 0; exattr <= 0; frame <= frame + 1'b1;
			end
			if (v_cnt >= (maxy+vrsz+7'd1)) begin 
				v_cnt <= 0;
				vrtc <= 0;
			end else v_cnt <= v_cnt+1'b1;
		end else begin
			v_str <= v_str + 1'd1;
		end
	end else begin
		h_cnt <= h_cnt+1'b1;
	end
end

endmodule
