let counter = 0;

Deno.serve({ port: 8080 }, (req) => {
  if (req.method === "GET") {
    counter++;
    return new Response(counter.toString(), {
      headers: { "content-type": "text/plain" },
    });
  }
  
  return new Response("Method not allowed", { status: 405 });
});

console.log("Counter server running on http://localhost:8080"); 
