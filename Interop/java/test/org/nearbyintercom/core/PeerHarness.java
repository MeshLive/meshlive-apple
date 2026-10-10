package org.nearbyintercom.core;

import org.json.*;
import java.io.*;
import java.util.*;
import static org.nearbyintercom.core.Wire.*;

/** Test-only process harness; stdin is a diagnostic pipe, never a shipped app transport. */
public final class PeerHarness {
    private static void output(String type, Object value) { System.out.println(new JSONObject().put("type",type).put("value",value)); }
    public static void main(String[] args) throws Exception {
        boolean initiator=args[0].equals("initiator"); int transport=Integer.parseInt(args[1]), mask=Integer.parseInt(args[2]), limit=Integer.parseInt(args[3]);
        byte[] token=unhex(args[4]); long[] recordID={0}; Assembler assembler=new Assembler(); Decoder decoder=new Decoder();
        Session s=new Session(initiator,Noise.randomKey(),new Capabilities(transport,mask,0,"Java reference"),token,0,null,null,record->{
            byte[] f=frame(record); List<byte[]> out=transport==1?chunks(f,recordID[0]++,limit):Collections.singletonList(f);
            for(byte[] b:out) output("out",hex(b));
        },new Session.Events(){
            public void verification(String code,String fingerprint){output("verification",code);}
            public void ready(Profile p){output("ready",hex(p.encoded()));}
            public void text(long id,String text){output("text",text);}
            public void acknowledged(long id){output("ack",id);}
            public void cancelled(long id){output("cancel",id);}
            public void audio(Media.Packet p){output("audio",hex(p.encoded()));}
            public void audioCancelled(long stream){output("audioCancel",stream);}
            public void closed(String reason){output("closed",reason);}
        });
        BufferedReader input=new BufferedReader(new InputStreamReader(System.in,java.nio.charset.StandardCharsets.UTF_8));
        String line;
        while((line=input.readLine())!=null){
            try {
                JSONObject command=new JSONObject(line); long now=command.optLong("now",2); String op=command.getString("op");
                switch(op){
                    case "start":s.start(now);break;
                    case "receive":
                        byte[] bytes=unhex(command.getString("hex")); if(transport==1)bytes=assembler.feed(bytes);
                        if(bytes!=null)for(byte[] r:decoder.feed(bytes))s.receive(r,now);break;
                    case "verify":s.verify(now);break;
                    case "text":s.sendText(command.getString("text"),now);break;
                    case "audio":s.audio(Media.Packet.decode(unhex(command.getString("hex")),s.profile),now);break;
                    case "audioCancel":s.cancelAudio(command.getLong("stream"),now);break;
                    case "tick":s.tick(now);break;
                    case "close":s.close("Interop check",now);break;
                    default:throw new Fault("Unknown harness command");
                }
            }catch(RuntimeException ex){output("error",ex.getMessage());}
            output("done",s.state.toString());
        }
    }
}
