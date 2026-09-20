## ADR-001: NorthStar Platform Foundation

### Status
Accepted

### Context
[What is NorthStar building? Why does a shared AI platform need an identity model and a storage tier structure from day one?]

NorthStar is building three different AI systems, and they all have different requirements, but share a lot of similar components. They need a platform that can support 3 different AI systems without each team duplicating work.

### Decision
[Describe the VPC topology, S3 prefix design, and IAM role model you built. Every rationale must tie to a NorthStar requirement — not "best practice."]

The vpc isolates the compute and storage network from other tenants in AWS and on the internet, while letting internal communication happen within NorthStar's private network. This allows communication to be fast and easy within the network. The S3 prefixes were used because NorthStar wanted to have a single data bucket for storage, and be able to transfer data easily between stages without incurring extra costs. The IAM model was used to protect the NorthStar's customer's data by enforcing prinicipals of least privilage. 

### Consequences
#### What this makes easy
What makes this easy is that once the initial engineering work has gone into the platform, then it should be relatively easy to add in additional ML models and workflows without needing to reengineer and copy the whole stack of tools and systems. This parellizes the process of creating and using models, and this should be much better for teams to have a single documented and standardized process for carrying out the training and inference and monitoring.

#### What this makes harder
What makes this harder is the initial upfront time and cost investment. No results are shown for the first several weeks of work, and the standardized production ready platform adds extra complexity and learning curve for engineers. This extra complexity could lead to higher ups wondering why there is so much work being done yet nothing to show for it while other companies are putting out new models left and right.

#### What would cause you to revisit this decision
If NorthStar decided to just go with a single ML model that they wanted to run for the foreseeable future, I would consider just building a simple point solution instead of investing the time and money into the upfront cost and relative complexity of building a full platform.

### Alternative Considered
[One genuinely different approach and why you rejected it]

The alternative to building a platform is building three much simpler point solutions. The advantages of point solutions are their relative simplicity and isolation. A set of standardized point solutions is genuinely a good alternative, but the approach of building a platform in this scenario is a better option due to the cost savings and overall reduction of duplication across teams.

### AWS Service Selection
- Networking isolation model
	- NorthStar wants to have an isolated section of the internet so that traffic can be controlled easily at a high level what can enter and exit. 
- Storage design
	- Storage was organized into separate sections inside a single bucket for convenience and budget reasons.
- Identity model
	- NorthStar decided to use the IAM model to protect the customer's data by enforcing principles of least privilege
- ML development environment
	- This was a go-to choice for powerful manipulation and training of ML models.