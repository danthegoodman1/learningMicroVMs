async function fetchAndLogStatus() {
  while (true) {
    try {
      let response = await fetch("http://1.1.1.1", { redirect: "manual" })

      console.log(`Response status from 1.1.1.1: ${response.status}`)

      if (!response.ok) {
        console.error(
          `HTTP error status: ${response.status} - ${response.statusText}`
        )
      }
    } catch (error) {
      console.error("Error during fetch: ", error)
    }

    try {
      // This should always fail to show it can't access local services, but can still go out to internet
      let response = await fetch("http://127.0.0.1:8080", {
        redirect: "manual",
      })

      console.log(`Response status from localhost: ${response.status}`)

      if (!response.ok) {
        console.error(
          `HTTP error status: ${response.status} - ${response.statusText}`
        )
      }
    } catch (error) {
      console.error("Error during fetch: ", error)
    }

    await new Promise((resolve) => setTimeout(resolve, 2000))
  }
}

if (import.meta.main) {
  fetchAndLogStatus()
}
