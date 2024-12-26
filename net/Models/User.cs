using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace UserApi.Models;
[Table("users")]
public class User
{
    [Key]
    [Column("id")]
    public int Id { get; set; }
    [Required]
    [Column("name")]
    public string Name { get; set; } = string.Empty;
    [Required]
    [Column("email")]
    public string Email { get; set; } = string.Empty;
}