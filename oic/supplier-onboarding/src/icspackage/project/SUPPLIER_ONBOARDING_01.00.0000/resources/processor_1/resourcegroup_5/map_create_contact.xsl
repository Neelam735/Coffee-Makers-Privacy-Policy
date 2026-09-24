<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="2.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:src="http://xmlns.example.com/oic/supplier-onboarding" xmlns:erp="http://xmlns.example.com/oic/erp/suppliers" exclude-result-prefixes="src erp">
   <!-- Template params: SupplierId = $CreateSupplier/SupplierId, childResource = 'contacts' -->
   <xsl:template match="/">
      <xsl:apply-templates select="(descendant-or-self::src:contacts)[1]"/>
   </xsl:template>
   <xsl:template match="src:contacts">
      <erp:SupplierChild>
         <erp:FirstName><xsl:value-of select="src:firstName"/></erp:FirstName>
         <erp:LastName><xsl:value-of select="src:lastName"/></erp:LastName>
         <xsl:if test="src:email"><erp:Email><xsl:value-of select="src:email"/></erp:Email></xsl:if>
         <xsl:if test="src:phone"><erp:PhoneNumber><xsl:value-of select="src:phone"/></erp:PhoneNumber></xsl:if>
      </erp:SupplierChild>
   </xsl:template>
</xsl:stylesheet>
