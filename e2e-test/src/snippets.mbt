///|
/// Small compile-only checks for the async runtime.
test "snippets" {
  let _ = @client_async.ServiceClient::new("http://localhost:8787/myapi")
  println("snippets: ok")
}
